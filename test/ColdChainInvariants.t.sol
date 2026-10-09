// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActorRegistry} from "../src/ActorRegistry.sol";
import {MedicineRegistry} from "../src/MedicineRegistry.sol";
import {ColdChainRegistry} from "../src/ColdChainRegistry.sol";
import {IActorRegistry, ActorType} from "../src/interfaces/IActorRegistry.sol";

contract ColdHandler is Test {
    ActorRegistry public actors;
    MedicineRegistry public medicine;
    ColdChainRegistry public cold;
    address public regulator;
    address public mfr;
    address public dist;

    address[] public sensors;
    uint256[] internal keys;
    bytes32[] public batches;

    mapping(address sensor => uint256) public anchors; // anclajes exitosos por sensor
    mapping(bytes32 sensorNonce => uint256) internal seen;

    bool public replayAccepted;
    bool public authViolation;
    bool public excursionMismatch;

    bytes32 constant TYPEHASH = keccak256(
        "Readings(bytes32 batchId,bytes32 readingsHash,int16 minDeciC,int16 maxDeciC,uint64 fromTs,uint64 toTs,uint256 nonce)"
    );

    constructor(ActorRegistry a, MedicineRegistry m, ColdChainRegistry c, address regulator_) {
        actors = a;
        medicine = m;
        cold = c;
        regulator = regulator_;
        mfr = makeAddr("mfr");
        dist = makeAddr("dist");

        vm.startPrank(regulator_);
        a.licenseActor(mfr, ActorType.Manufacturer, uint64(block.timestamp + 365 days));
        a.licenseActor(dist, ActorType.Distributor, uint64(block.timestamp + 365 days));
        vm.stopPrank();

        for (uint256 i = 0; i < 2; i++) {
            vm.prank(mfr);
            batches.push(
                m.registerBatch(
                    keccak256("GTIN"),
                    keccak256(abi.encode("LOT", i)),
                    keccak256("root"),
                    uint64(block.timestamp + 365 days)
                )
            );
        }
        for (uint256 i = 0; i < 3; i++) {
            (address s, uint256 k) = makeAddrAndKey(string(abi.encodePacked("sensor", vm.toString(i))));
            sensors.push(s);
            keys.push(k);
            vm.prank(i < 2 ? mfr : dist);
            c.registerSensor(s);
        }
    }

    struct Ctx {
        address sensor;
        uint256 si;
        bytes32 batch;
        uint256 expected;
        uint256 nonce;
        int256 mn;
        int256 mx;
        bool authOk; // dueno habilitado + con licencia vigente + con la custodia del lote
        uint256 excBefore;
    }

    function anchor(uint256 sSeed, uint256 bSeed, uint256 mode, uint256 tMin, uint256 span, uint256 hSeed) external {
        Ctx memory c = _ctx(sSeed, bSeed, mode, tMin, span);
        ColdChainRegistry.Readings memory r = _readings(c, hSeed);
        bytes memory sig = _sign(keys[c.si], r);
        try cold.anchorReadings(r, sig) {
            _onSuccess(c);
        } catch {}
    }

    function _ctx(uint256 sSeed, uint256 bSeed, uint256 mode, uint256 tMin, uint256 span)
        internal
        view
        returns (Ctx memory c)
    {
        c.si = sSeed % sensors.length;
        c.sensor = sensors[c.si];
        c.batch = batches[bSeed % batches.length];
        c.expected = cold.nextNonce(c.sensor);
        // 1/3 replay (nonce viejo), 1/3 salto (nonce futuro), 1/3 correcto
        c.nonce = (mode % 3 == 0 && c.expected > 0) ? c.expected - 1 : (mode % 3 == 1 ? c.expected + 1 : c.expected);
        c.mn = int256(bound(tMin, 0, 200)) - 50;
        c.mx = c.mn + int256(bound(span, 0, 100));
        address owner_ = cold.sensorOwner(c.sensor);
        c.authOk = owner_ != address(0) && actors.activeTypeOf(owner_) != ActorType.None
            && medicine.getBatch(c.batch).custodian == owner_;
        c.excBefore = cold.excursionCount(c.batch);
    }

    function _readings(Ctx memory c, uint256 hSeed) internal view returns (ColdChainRegistry.Readings memory) {
        return ColdChainRegistry.Readings({
            batchId: c.batch,
            readingsHash: keccak256(abi.encode(hSeed, c.nonce)),
            minDeciC: int16(c.mn),
            maxDeciC: int16(c.mx),
            fromTs: uint64(block.timestamp - 100),
            toTs: uint64(block.timestamp - 1),
            nonce: c.nonce
        });
    }

    function _onSuccess(Ctx memory c) internal {
        anchors[c.sensor]++;
        if (++seen[keccak256(abi.encode(c.sensor, c.nonce))] > 1) replayAccepted = true;
        if (c.nonce != c.expected || !c.authOk) authViolation = true;
        uint256 want = (c.mn < 20 || c.mx > 80) ? 1 : 0;
        if (cold.excursionCount(c.batch) - c.excBefore != want) excursionMismatch = true;
    }

    function transferBatch(uint256 bSeed) external {
        bytes32 id = batches[bSeed % batches.length];
        vm.prank(medicine.getBatch(id).custodian);
        try medicine.transferCustody(id, dist) {} catch {}
    }

    function revoke(uint256 sSeed) external {
        address s = sensors[sSeed % sensors.length];
        address owner_ = cold.sensorOwner(s);
        if (owner_ == address(0)) return;
        vm.prank(owner_);
        cold.revokeSensor(s);
    }

    function suspend(uint256 seed) external {
        vm.prank(regulator);
        actors.suspendActor(seed % 2 == 0 ? mfr : dist, keccak256("x"));
    }

    function reinstate(uint256 seed) external {
        vm.prank(regulator);
        actors.reinstateActor(seed % 2 == 0 ? mfr : dist);
    }

    function sensorsLength() external view returns (uint256) {
        return sensors.length;
    }

    function batchesLength() external view returns (uint256) {
        return batches.length;
    }

    function _sign(uint256 pk, ColdChainRegistry.Readings memory r) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(TYPEHASH, r.batchId, r.readingsHash, r.minDeciC, r.maxDeciC, r.fromTs, r.toTs, r.nonce)
        );
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("PharmaTraceColdChain")),
                keccak256(bytes("1")),
                block.chainid,
                address(cold)
            )
        );
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        return abi.encodePacked(rr, s, v);
    }
}

contract ColdChainInvariantsTest is Test {
    ActorRegistry actors;
    MedicineRegistry med;
    ColdChainRegistry cold;
    ColdHandler handler;
    address regulator = makeAddr("regulator");

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.startPrank(regulator);
        actors = new ActorRegistry(regulator);
        actors.grantRole(actors.REGULATOR_ROLE(), regulator);
        med = new MedicineRegistry(IActorRegistry(address(actors)));
        cold = new ColdChainRegistry(IActorRegistry(address(actors)), med, 20, 80);
        vm.stopPrank();

        handler = new ColdHandler(actors, med, cold, regulator);
        targetContract(address(handler));
    }

    /// El nonce de cada sensor avanza exactamente una vez por anclaje exitoso: sin saltos ni retrocesos.
    function invariant_NonceEqualsSuccessfulAnchors() public view {
        for (uint256 i = 0; i < handler.sensorsLength(); i++) {
            address s = handler.sensors(i);
            assertEq(cold.nextNonce(s), handler.anchors(s), "nonce desfasado");
        }
    }

    /// Ninguna firma se acepta dos veces, y nadie ancla sin autorizacion, custodia o con excursion mal contada.
    function invariant_NoReplayNoAuthViolation() public view {
        assertFalse(handler.replayAccepted(), "replay aceptado");
        assertFalse(handler.authViolation(), "anclaje sin autorizacion");
        assertFalse(handler.excursionMismatch(), "excursion mal contada");
    }

    /// Los contadores por lote son consistentes con los anclajes totales.
    function invariant_CountersConsistent() public view {
        uint256 byBatch;
        uint256 bySensor;
        for (uint256 i = 0; i < handler.batchesLength(); i++) {
            bytes32 id = handler.batches(i);
            assertLe(cold.excursionCount(id), cold.anchorCount(id), "mas excursiones que anclajes");
            byBatch += cold.anchorCount(id);
        }
        for (uint256 i = 0; i < handler.sensorsLength(); i++) {
            bySensor += handler.anchors(handler.sensors(i));
        }
        assertEq(byBatch, bySensor, "contadores inconsistentes");
    }
}
