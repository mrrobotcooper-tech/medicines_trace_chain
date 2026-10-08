// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActorRegistry} from "../src/ActorRegistry.sol";
import {MedicineRegistry} from "../src/MedicineRegistry.sol";
import {IActorRegistry, ActorType} from "../src/interfaces/IActorRegistry.sol";

/// @notice Genera acciones aleatorias pero acotadas sobre el sistema y registra "ghost state"
///         (lo que DEBERIA haber pasado) para que los invariants lo comparen con el contrato real.
///         Las violaciones se acumulan en flags en lugar de hacer assert aqui: asi el invariant
///         que falla queda identificado por nombre.
contract PharmaHandler is Test {
    ActorRegistry public actors;
    MedicineRegistry public reg;
    address public regulator;

    bytes32 public constant PRODUCT = keccak256("GTIN-INVARIANTS");
    bytes32 public root;
    bytes32[4] internal serials;
    bytes32[4] internal leaves;
    bytes32 internal n01;
    bytes32 internal n23;

    address[] public mfrs;
    address[] internal dists;
    address[] internal pharms;
    address[] internal outsiders; // nunca licenciados
    address[] internal all;
    address[] internal licensed;
    mapping(address => ActorType) public typeOf;

    bytes32[] public batchIds;
    mapping(bytes32 => MedicineRegistry.Batch) internal snap; // ultimo estado observado

    struct Unit {
        bytes32 batchId;
        bytes32 serial;
    }

    Unit[] public units; // unidades dispensadas con exito (al menos una vez)
    mapping(bytes32 unitKey => uint256) public dispensedCount;
    mapping(bytes32 batchId => uint256) public batchDispensed;
    mapping(bytes32 batchId => uint256) public dispensedAtRecall;
    mapping(bytes32 batchId => bool) public recalled;

    // Flags de violacion (deben permanecer en false)
    bool public authViolation;
    bool public forgedAccepted;
    bool public immutableViolated;
    bool public custodyRegressed;
    bool public movedAfterRecall;
    bool public recallReverted;

    constructor(ActorRegistry a, MedicineRegistry r, address regulator_) {
        actors = a;
        reg = r;
        regulator = regulator_;

        for (uint256 i = 0; i < 4; i++) {
            serials[i] = keccak256(abi.encode("SN", i));
            leaves[i] = keccak256(abi.encodePacked(serials[i]));
        }
        n01 = _pair(leaves[0], leaves[1]);
        n23 = _pair(leaves[2], leaves[3]);
        root = _pair(n01, n23);

        mfrs.push(makeAddr("mfr1"));
        mfrs.push(makeAddr("mfr2"));
        dists.push(makeAddr("dist1"));
        dists.push(makeAddr("dist2"));
        pharms.push(makeAddr("pharm1"));
        pharms.push(makeAddr("pharm2"));
        outsiders.push(makeAddr("out1"));
        outsiders.push(makeAddr("out2"));

        uint64 exp = uint64(block.timestamp + 365 days);
        vm.startPrank(regulator_);
        for (uint256 i = 0; i < 2; i++) {
            _license(mfrs[i], ActorType.Manufacturer, exp);
            _license(dists[i], ActorType.Distributor, exp);
            _license(pharms[i], ActorType.Pharmacy, exp);
        }
        vm.stopPrank();

        for (uint256 i = 0; i < 2; i++) {
            all.push(mfrs[i]);
            all.push(dists[i]);
            all.push(pharms[i]);
            all.push(outsiders[i]);
        }
    }

    // ------------------------------------------------------------------
    // Acciones
    // ------------------------------------------------------------------

    function registerBatch(uint256 actorSeed, uint256 lotSeed, uint256 expiryDelta) external {
        address who = all[actorSeed % all.length];
        bytes32 lot = keccak256(abi.encode("LOT", lotSeed % 3));
        uint64 expiry = uint64(block.timestamp + bound(expiryDelta, 1 days, 400 days));
        bool wasManufacturer = actors.activeTypeOf(who) == ActorType.Manufacturer;

        vm.prank(who);
        try reg.registerBatch(PRODUCT, lot, root, expiry) returns (bytes32 id) {
            if (!wasManufacturer) authViolation = true;
            batchIds.push(id);
            snap[id] = reg.getBatch(id);
        } catch {}
    }

    function transferCustody(uint256 batchSeed, uint256 fromSeed, uint256 toSeed) external {
        if (batchIds.length == 0) return;
        bytes32 id = batchIds[batchSeed % batchIds.length];
        MedicineRegistry.Batch memory pre = reg.getBatch(id);

        // La mitad de las veces actua el custodio real: sin este sesgo casi todo revertiria.
        address from = fromSeed % 2 == 0 ? pre.custodian : all[fromSeed % all.length];
        address to = all[toSeed % all.length];
        ActorType fromActive = actors.activeTypeOf(from);
        ActorType toActive = actors.activeTypeOf(to);

        vm.prank(from);
        try reg.transferCustody(id, to) {
            if (
                from != pre.custodian || fromActive != pre.custodianType || pre.custodianType == ActorType.Pharmacy
                    || pre.status == MedicineRegistry.BatchStatus.Recalled || block.timestamp > pre.expiry
                    || (toActive != ActorType.Distributor && toActive != ActorType.Pharmacy)
            ) {
                authViolation = true;
            }
        } catch {}
        _observe(id);
    }

    function dispense(uint256 batchSeed, uint256 callerSeed, uint256 serialSeed) external {
        if (batchIds.length == 0) return;
        bytes32 id = batchIds[batchSeed % batchIds.length];
        MedicineRegistry.Batch memory pre = reg.getBatch(id);

        address who = callerSeed % 2 == 0 ? pre.custodian : all[callerSeed % all.length];
        ActorType whoActive = actors.activeTypeOf(who);
        uint256 i = serialSeed % 4;
        bool fake = serialSeed % 7 == 0;
        bytes32 serial = fake ? keccak256(abi.encode("FAKE", serialSeed)) : serials[i];
        bytes32[] memory proof = _proofFor(i);

        vm.prank(who);
        try reg.dispense(id, serial, proof) {
            if (fake) forgedAccepted = true;
            bytes32 key = keccak256(abi.encode(id, serial));
            if (dispensedCount[key] == 0) units.push(Unit(id, serial));
            dispensedCount[key]++;
            batchDispensed[id]++;
            if (
                who != pre.custodian || pre.custodianType != ActorType.Pharmacy || whoActive != ActorType.Pharmacy
                    || pre.status == MedicineRegistry.BatchStatus.Recalled || block.timestamp > pre.expiry
            ) {
                authViolation = true;
            }
        } catch {}
        _observe(id);
    }

    function recallBatch(uint256 batchSeed, uint256 callerSeed) external {
        if (batchIds.length == 0) return;
        bytes32 id = batchIds[batchSeed % batchIds.length];
        MedicineRegistry.Batch memory pre = reg.getBatch(id);

        address who;
        uint256 pick = callerSeed % (all.length + 2);
        if (pick == all.length) who = regulator;
        else if (pick == all.length + 1) who = pre.manufacturer;
        else who = all[pick];

        vm.prank(who);
        try reg.recallBatch(id, keccak256("motivo")) {
            if (who != pre.manufacturer && who != regulator) authViolation = true;
            recalled[id] = true;
            dispensedAtRecall[id] = batchDispensed[id];
        } catch {}
        _observe(id);
    }

    function suspend(uint256 seed) external {
        vm.prank(regulator);
        actors.suspendActor(licensed[seed % licensed.length], keccak256("inspeccion"));
    }

    function reinstate(uint256 seed) external {
        vm.prank(regulator);
        actors.reinstateActor(licensed[seed % licensed.length]);
    }

    function renew(uint256 seed, uint256 extra) external {
        address a = licensed[seed % licensed.length];
        vm.prank(regulator);
        actors.licenseActor(a, typeOf[a], uint64(block.timestamp + bound(extra, 1 days, 365 days)));
    }

    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 90 days));
    }

    // ------------------------------------------------------------------
    // Vistas para los invariants
    // ------------------------------------------------------------------

    function batchIdsLength() external view returns (uint256) {
        return batchIds.length;
    }

    function unitsLength() external view returns (uint256) {
        return units.length;
    }

    // ------------------------------------------------------------------
    // Internos
    // ------------------------------------------------------------------

    function _license(address a, ActorType t, uint64 exp) internal {
        actors.licenseActor(a, t, exp);
        typeOf[a] = t;
        licensed.push(a);
    }

    /// @dev Compara el estado actual con el ultimo observado y marca cualquier regresion.
    function _observe(bytes32 id) internal {
        MedicineRegistry.Batch memory b = reg.getBatch(id);
        MedicineRegistry.Batch memory s = snap[id];

        if (
            b.productHash != s.productHash || b.lotHash != s.lotHash || b.serialsRoot != s.serialsRoot
                || b.manufacturer != s.manufacturer || b.expiry != s.expiry || b.createdAt != s.createdAt
        ) {
            immutableViolated = true;
        }
        if (uint8(b.custodianType) < uint8(s.custodianType)) custodyRegressed = true;
        if (s.custodianType == ActorType.Pharmacy && b.custodian != s.custodian) custodyRegressed = true;
        if (s.status == MedicineRegistry.BatchStatus.Recalled) {
            if (b.status != MedicineRegistry.BatchStatus.Recalled) recallReverted = true;
            if (b.custodian != s.custodian) movedAfterRecall = true;
        }
        snap[id] = b;
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _proofFor(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        if (i == 0) {
            p[0] = leaves[1];
            p[1] = n23;
        } else if (i == 1) {
            p[0] = leaves[0];
            p[1] = n23;
        } else if (i == 2) {
            p[0] = leaves[3];
            p[1] = n01;
        } else {
            p[0] = leaves[2];
            p[1] = n01;
        }
    }
}

contract PharmaInvariantsTest is Test {
    ActorRegistry actors;
    MedicineRegistry reg;
    PharmaHandler handler;
    address regulator = makeAddr("regulator");

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.startPrank(regulator);
        actors = new ActorRegistry(regulator);
        actors.grantRole(actors.REGULATOR_ROLE(), regulator);
        reg = new MedicineRegistry(IActorRegistry(address(actors)));
        vm.stopPrank();

        handler = new PharmaHandler(actors, reg, regulator);
        targetContract(address(handler));
    }

    /// Una misma serie nunca se dispensa dos veces, bajo ninguna secuencia de acciones.
    function invariant_SerialDispensedAtMostOnce() public view {
        uint256 n = handler.unitsLength();
        for (uint256 i = 0; i < n; i++) {
            (bytes32 batchId, bytes32 serial) = handler.units(i);
            assertEq(handler.dispensedCount(keccak256(abi.encode(batchId, serial))), 1, "serie dispensada >1 vez");
        }
    }

    /// Lo dispensado queda dispensado: el estado nunca retrocede.
    function invariant_DispensedStaysDispensed() public view {
        uint256 n = handler.unitsLength();
        for (uint256 i = 0; i < n; i++) {
            (bytes32 batchId, bytes32 serial) = handler.units(i);
            assertTrue(reg.isDispensed(batchId, serial), "dispensado revertido");
        }
    }

    /// Una serie que no esta en el arbol Merkle nunca es aceptada.
    function invariant_ForgedSerialNeverAccepted() public view {
        assertFalse(handler.forgedAccepted(), "se acepto una serie falsificada");
    }

    /// Hashes, fabricante, vencimiento y fecha de creacion no cambian despues del registro.
    function invariant_BatchDataIsImmutable() public view {
        assertFalse(handler.immutableViolated(), "se modificaron datos del lote");
    }

    /// Laboratorio -> drogueria -> farmacia; la farmacia es final.
    function invariant_CustodyNeverRegresses() public view {
        assertFalse(handler.custodyRegressed(), "la custodia retrocedio");
    }

    /// Tras un recall nada se mueve y el lote no vuelve a estado activo.
    function invariant_NothingMovesAfterRecall() public view {
        assertFalse(handler.movedAfterRecall(), "custodia cambio tras recall");
        assertFalse(handler.recallReverted(), "el recall se revirtio");
        uint256 n = handler.batchIdsLength();
        for (uint256 i = 0; i < n; i++) {
            bytes32 id = handler.batchIds(i);
            if (handler.recalled(id)) {
                assertEq(handler.batchDispensed(id), handler.dispensedAtRecall(id), "dispensa tras recall");
            }
        }
    }

    /// Nadie sin licencia vigente (o sin ser custodio) logra registrar, transferir, dispensar o retirar.
    function invariant_NoAuthorizationViolation() public view {
        assertFalse(handler.authViolation(), "operacion exitosa sin autorizacion");
    }

    /// Solo fabricantes licenciados terminan siendo duenos de lotes, y ningun lote desaparece.
    function invariant_OnlyLicensedManufacturersOwnBatches() public view {
        uint256 n = handler.batchIdsLength();
        address m0 = handler.mfrs(0);
        address m1 = handler.mfrs(1);
        for (uint256 i = 0; i < n; i++) {
            MedicineRegistry.Batch memory b = reg.getBatch(handler.batchIds(i));
            assertTrue(b.manufacturer == m0 || b.manufacturer == m1, "lote de un no-fabricante");
            assertTrue(b.status != MedicineRegistry.BatchStatus.None, "lote desaparecio");
        }
    }
}
