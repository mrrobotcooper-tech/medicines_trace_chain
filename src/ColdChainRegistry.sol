// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IActorRegistry, ActorType} from "./interfaces/IActorRegistry.sol";
import {MedicineRegistry} from "./MedicineRegistry.sol";

/// @notice Ancla resumenes de lecturas de temperatura firmados por sensores habilitados.
/// @dev Lo que se puede afirmar: "este sensor firmo estos datos y no cambiaron desde el anclaje".
///      Lo que NO se puede afirmar: que la temperatura real fuera esa. Un sensor manipulado o con la
///      clave robada firma mentiras igual de bien; por eso existe la revocacion y el vinculo con la custodia.
///      Anti-replay: nonce secuencial por sensor + dominio EIP-712 (chainId + direccion del contrato).
///      Quien envia la transaccion NO importa: la firma autentica los datos, no el relayer.
///      Limitacion consciente: el rango permitido es global (demo 2-8 C), no por producto.
contract ColdChainRegistry is EIP712 {
    struct Readings {
        bytes32 batchId;
        bytes32 readingsHash; // hash del archivo completo de lecturas (vive off-chain)
        int16 minDeciC; // decimas de grado: 25 = 2.5 C
        int16 maxDeciC;
        uint64 fromTs;
        uint64 toTs;
        uint256 nonce;
    }

    bytes32 public constant READINGS_TYPEHASH = keccak256(
        "Readings(bytes32 batchId,bytes32 readingsHash,int16 minDeciC,int16 maxDeciC,uint64 fromTs,uint64 toTs,uint256 nonce)"
    );

    IActorRegistry public immutable actors;
    MedicineRegistry public immutable medicine;
    int16 public immutable minAllowedDeciC;
    int16 public immutable maxAllowedDeciC;

    mapping(address sensor => address owner) public sensorOwner;
    mapping(address sensor => bool) public revoked;
    mapping(address sensor => uint256) public nextNonce;
    mapping(bytes32 batchId => uint32) public anchorCount;
    mapping(bytes32 batchId => uint32) public excursionCount;

    event SensorRegistered(address indexed sensor, address indexed owner);
    event SensorRevoked(address indexed sensor, address indexed by);
    event ReadingsAnchored(
        bytes32 indexed batchId,
        address indexed sensor,
        uint256 nonce,
        bytes32 readingsHash,
        int16 minDeciC,
        int16 maxDeciC,
        uint64 fromTs,
        uint64 toTs
    );
    event ColdChainExcursion(bytes32 indexed batchId, address indexed sensor, int16 minDeciC, int16 maxDeciC);

    error NotAuthorized(address account);
    error InvalidSensor();
    error SensorAlreadyRegistered(address sensor);
    error SensorRevokedError(address sensor);
    error SensorNotRegistered(address sensor);
    error SensorNotInCustody(bytes32 batchId, address sensor);
    error InvalidSignature();
    error InvalidNonce(uint256 expected, uint256 got);
    error InvalidRange();
    error InvalidTimeWindow();
    error InvalidHash();

    constructor(IActorRegistry a, MedicineRegistry m, int16 minAllowed, int16 maxAllowed)
        EIP712("PharmaTraceColdChain", "1")
    {
        if (minAllowed >= maxAllowed) revert InvalidRange();
        actors = a;
        medicine = m;
        minAllowedDeciC = minAllowed;
        maxAllowedDeciC = maxAllowed;
    }

    function registerSensor(address sensor) external {
        if (actors.activeTypeOf(msg.sender) == ActorType.None) revert NotAuthorized(msg.sender);
        if (sensor == address(0)) revert InvalidSensor();
        if (revoked[sensor]) revert SensorRevokedError(sensor);
        if (sensorOwner[sensor] != address(0)) revert SensorAlreadyRegistered(sensor);
        sensorOwner[sensor] = msg.sender;
        emit SensorRegistered(sensor, msg.sender);
    }

    /// @dev La revocacion es permanente: una clave comprometida no puede volver a enrolarse.
    ///      El dueno puede revocar aunque su licencia haya vencido (es una accion de seguridad).
    function revokeSensor(address sensor) external {
        address owner_ = sensorOwner[sensor];
        if (owner_ == address(0)) revert SensorNotRegistered(sensor);
        if (msg.sender != owner_ && !actors.isRegulator(msg.sender)) revert NotAuthorized(msg.sender);
        sensorOwner[sensor] = address(0);
        revoked[sensor] = true;
        emit SensorRevoked(sensor, msg.sender);
    }

    function anchorReadings(Readings calldata r, bytes calldata signature) external {
        if (r.readingsHash == bytes32(0)) revert InvalidHash();
        if (r.minDeciC > r.maxDeciC) revert InvalidRange();
        if (r.fromTs >= r.toTs || r.toTs > block.timestamp) revert InvalidTimeWindow();

        // Revierte con BatchNotFound si el lote no existe.
        MedicineRegistry.Batch memory b = medicine.getBatch(r.batchId);

        address sensor = _recoverSensor(r, signature);
        address owner_ = sensorOwner[sensor];
        if (owner_ == address(0)) revert SensorNotRegistered(sensor);
        if (actors.activeTypeOf(owner_) == ActorType.None) revert NotAuthorized(owner_);
        if (b.custodian != owner_) revert SensorNotInCustody(r.batchId, sensor);

        uint256 expected = nextNonce[sensor];
        if (r.nonce != expected) revert InvalidNonce(expected, r.nonce);
        nextNonce[sensor] = expected + 1;
        anchorCount[r.batchId]++;

        emit ReadingsAnchored(
            r.batchId, sensor, r.nonce, r.readingsHash, r.minDeciC, r.maxDeciC, r.fromTs, r.toTs
        );

        // Se ancla siempre, incluso fuera de rango: ocultar una excursion seria peor que registrarla.
        if (r.minDeciC < minAllowedDeciC || r.maxDeciC > maxAllowedDeciC) {
            excursionCount[r.batchId]++;
            emit ColdChainExcursion(r.batchId, sensor, r.minDeciC, r.maxDeciC);
        }
    }

    /// @notice Digest EIP-712 que el sensor debe firmar (util para herramientas off-chain).
    function hashReadings(Readings calldata r) public view returns (bytes32) {
        return _hashTypedDataV4(
            keccak256(
                abi.encode(
                    READINGS_TYPEHASH, r.batchId, r.readingsHash, r.minDeciC, r.maxDeciC, r.fromTs, r.toTs, r.nonce
                )
            )
        );
    }

    function _recoverSensor(Readings calldata r, bytes calldata signature) private view returns (address) {
        (address signer, ECDSA.RecoverError err,) = ECDSA.tryRecover(hashReadings(r), signature);
        if (err != ECDSA.RecoverError.NoError || signer == address(0)) revert InvalidSignature();
        return signer;
    }
}
