// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {IActorRegistry, ActorType} from "./interfaces/IActorRegistry.sol";

/// @notice Trazabilidad de medicamentos a nivel LOTE, con verificacion de unidades por Merkle proof.
/// @dev Diseno:
///  - On-chain solo hay hashes: producto, lote y la raiz Merkle de los numeros de serie del lote.
///    Registrar cada serie on-chain seria carisimo; con la raiz alcanza para verificar cualquier unidad.
///  - La cadena de custodia (laboratorio -> drogueria -> farmacia) se valida contra ActorRegistry.
///  - dispense() marca una unidad como dispensada: detecta reuso/duplicacion de una misma serie.
///  - No hay datos de pacientes ni recetas on-chain.
///  - Limitacion consciente: la custodia es por lote completo (no se fracciona un lote entre varias farmacias).
///  - on-chain != verdad: prueba que el dato no cambio desde el anclaje, no que sea cierto.
contract MedicineRegistry {
    enum BatchStatus {
        None,
        Active,
        Recalled
    }

    enum VerifyResult {
        UnknownBatch,
        Recalled,
        Expired,
        InvalidProof,
        AlreadyDispensed,
        Valid
    }

    // Orden de campos pensado para packing: manufacturer+expiry en un slot, custodian+createdAt+status+custodianType en otro.
    struct Batch {
        bytes32 productHash; // keccak256(bytes(GTIN))
        bytes32 lotHash; // keccak256(bytes(lote))
        bytes32 serialsRoot; // raiz Merkle de los numeros de serie
        address manufacturer;
        uint64 expiry;
        address custodian;
        uint64 createdAt;
        BatchStatus status;
        ActorType custodianType;
    }

    IActorRegistry public immutable actors;

    mapping(bytes32 batchId => Batch) private _batches;
    mapping(bytes32 unitKey => bool) private _dispensed;

    event BatchRegistered(
        bytes32 indexed batchId,
        address indexed manufacturer,
        bytes32 productHash,
        bytes32 lotHash,
        bytes32 serialsRoot,
        uint64 expiry
    );
    event CustodyTransferred(bytes32 indexed batchId, address indexed from, address indexed to, ActorType toType);
    event BatchRecalled(bytes32 indexed batchId, address indexed by, bytes32 reasonHash);
    event UnitDispensed(bytes32 indexed batchId, bytes32 indexed serial, address indexed pharmacy);

    error NotAuthorized(address account);
    error InvalidHash();
    error InvalidExpiry();
    error BatchAlreadyExists(bytes32 batchId);
    error BatchNotFound(bytes32 batchId);
    error BatchRecalledError(bytes32 batchId);
    error BatchExpired(bytes32 batchId);
    error NotCustodian(bytes32 batchId, address account);
    error InvalidReceiver(address account);
    error FinalCustody(bytes32 batchId);
    error InvalidProof();
    error AlreadyDispensed(bytes32 batchId, bytes32 serial);

    constructor(IActorRegistry actorRegistry) {
        actors = actorRegistry;
    }

    /// @dev El manufacturer forma parte del id: nadie puede "ocupar" el lote de otro laboratorio.
    function computeBatchId(address manufacturer, bytes32 productHash, bytes32 lotHash)
        public
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(manufacturer, productHash, lotHash));
    }

    function registerBatch(bytes32 productHash, bytes32 lotHash, bytes32 serialsRoot, uint64 expiry)
        external
        returns (bytes32 batchId)
    {
        if (actors.activeTypeOf(msg.sender) != ActorType.Manufacturer) revert NotAuthorized(msg.sender);
        if (productHash == 0 || lotHash == 0 || serialsRoot == 0) revert InvalidHash();
        if (expiry <= block.timestamp) revert InvalidExpiry();

        batchId = computeBatchId(msg.sender, productHash, lotHash);
        if (_batches[batchId].status != BatchStatus.None) revert BatchAlreadyExists(batchId);

        _batches[batchId] = Batch({
            productHash: productHash,
            lotHash: lotHash,
            serialsRoot: serialsRoot,
            manufacturer: msg.sender,
            expiry: expiry,
            custodian: msg.sender,
            createdAt: uint64(block.timestamp),
            status: BatchStatus.Active,
            custodianType: ActorType.Manufacturer
        });

        emit BatchRegistered(batchId, msg.sender, productHash, lotHash, serialsRoot, expiry);
    }

    function transferCustody(bytes32 batchId, address to) external {
        Batch storage b = _batch(batchId);
        if (b.status == BatchStatus.Recalled) revert BatchRecalledError(batchId);
        if (b.expiry < block.timestamp) revert BatchExpired(batchId);
        if (msg.sender != b.custodian) revert NotCustodian(batchId, msg.sender);
        if (b.custodianType == ActorType.Pharmacy) revert FinalCustody(batchId);
        // El custodio debe seguir habilitado: una licencia vencida o suspendida no puede despachar.
        if (actors.activeTypeOf(msg.sender) != b.custodianType) revert NotAuthorized(msg.sender);

        ActorType toType = actors.activeTypeOf(to);
        if (to == msg.sender || (toType != ActorType.Distributor && toType != ActorType.Pharmacy)) {
            revert InvalidReceiver(to);
        }

        address from = b.custodian;
        b.custodian = to;
        b.custodianType = toType;
        emit CustodyTransferred(batchId, from, to, toType);
    }

    /// @dev El fabricante puede retirar su lote aunque su licencia haya vencido: una accion
    ///      de seguridad sanitaria no debe quedar bloqueada por tramites. Irreversible en esta version.
    function recallBatch(bytes32 batchId, bytes32 reasonHash) external {
        Batch storage b = _batch(batchId);
        if (msg.sender != b.manufacturer && !actors.isRegulator(msg.sender)) revert NotAuthorized(msg.sender);
        if (b.status == BatchStatus.Recalled) revert BatchRecalledError(batchId);
        b.status = BatchStatus.Recalled;
        emit BatchRecalled(batchId, msg.sender, reasonHash);
    }

    /// @param serial hash del numero de serie: keccak256(bytes(serialString))
    function dispense(bytes32 batchId, bytes32 serial, bytes32[] calldata proof) external {
        Batch storage b = _batch(batchId);
        if (b.status == BatchStatus.Recalled) revert BatchRecalledError(batchId);
        if (b.expiry < block.timestamp) revert BatchExpired(batchId);
        if (b.custodianType != ActorType.Pharmacy || msg.sender != b.custodian) {
            revert NotCustodian(batchId, msg.sender);
        }
        if (actors.activeTypeOf(msg.sender) != ActorType.Pharmacy) revert NotAuthorized(msg.sender);
        if (!MerkleProof.verifyCalldata(proof, b.serialsRoot, _leaf(serial))) revert InvalidProof();

        bytes32 key = keccak256(abi.encode(batchId, serial));
        if (_dispensed[key]) revert AlreadyDispensed(batchId, serial);
        _dispensed[key] = true;

        emit UnitDispensed(batchId, serial, msg.sender);
    }

    /// @notice Verificacion de solo lectura que puede hacer cualquiera (farmacia, auditor, consumidor).
    function verifyUnit(bytes32 batchId, bytes32 serial, bytes32[] calldata proof)
        external
        view
        returns (VerifyResult)
    {
        Batch storage b = _batches[batchId];
        if (b.status == BatchStatus.None) return VerifyResult.UnknownBatch;
        if (b.status == BatchStatus.Recalled) return VerifyResult.Recalled;
        if (b.expiry < block.timestamp) return VerifyResult.Expired;
        if (!MerkleProof.verifyCalldata(proof, b.serialsRoot, _leaf(serial))) return VerifyResult.InvalidProof;
        if (_dispensed[keccak256(abi.encode(batchId, serial))]) return VerifyResult.AlreadyDispensed;
        return VerifyResult.Valid;
    }

    function getBatch(bytes32 batchId) external view returns (Batch memory) {
        return _batch(batchId);
    }

    function isDispensed(bytes32 batchId, bytes32 serial) external view returns (bool) {
        return _dispensed[keccak256(abi.encode(batchId, serial))];
    }

    /// @dev Hoja = keccak256 de 32 bytes; nodos internos = keccak256 de 64 bytes. Longitudes distintas
    ///      evitan el ataque de segunda preimagen sin necesidad de doble hash.
    function _leaf(bytes32 serial) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(serial));
    }

    function _batch(bytes32 batchId) private view returns (Batch storage b) {
        b = _batches[batchId];
        if (b.status == BatchStatus.None) revert BatchNotFound(batchId);
    }
}
