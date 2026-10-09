// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActorRegistry} from "../src/ActorRegistry.sol";
import {MedicineRegistry} from "../src/MedicineRegistry.sol";
import {ColdChainRegistry} from "../src/ColdChainRegistry.sol";
import {IActorRegistry, ActorType} from "../src/interfaces/IActorRegistry.sol";

contract ColdChainTest is Test {
    ActorRegistry actors;
    MedicineRegistry med;
    ColdChainRegistry cold;

    address regulator = makeAddr("regulator");
    address mfr = makeAddr("laboratorio");
    address dist = makeAddr("drogueria");
    address stranger = makeAddr("stranger");
    address relayer = makeAddr("relayer");
    address sensor;
    uint256 sensorKey;

    uint64 constant T0 = 1_700_000_000;
    bytes32 constant TYPEHASH = keccak256(
        "Readings(bytes32 batchId,bytes32 readingsHash,int16 minDeciC,int16 maxDeciC,uint64 fromTs,uint64 toTs,uint256 nonce)"
    );
    bytes32 batchId;

    function setUp() public {
        vm.warp(T0);
        (sensor, sensorKey) = makeAddrAndKey("sensor");

        vm.startPrank(regulator);
        actors = new ActorRegistry(regulator);
        actors.grantRole(actors.REGULATOR_ROLE(), regulator);
        med = new MedicineRegistry(IActorRegistry(address(actors)));
        cold = new ColdChainRegistry(IActorRegistry(address(actors)), med, 20, 80);
        actors.licenseActor(mfr, ActorType.Manufacturer, T0 + 365 days);
        actors.licenseActor(dist, ActorType.Distributor, T0 + 365 days);
        vm.stopPrank();

        vm.startPrank(mfr);
        batchId = med.registerBatch(keccak256("GTIN"), keccak256("LOTE"), keccak256("root"), T0 + 300 days);
        cold.registerSensor(sensor);
        vm.stopPrank();
    }

    // ---------- helpers ----------
    function _r(uint256 nonce, int16 mn, int16 mx) internal view returns (ColdChainRegistry.Readings memory) {
        return ColdChainRegistry.Readings({
            batchId: batchId,
            readingsHash: keccak256(abi.encode("lecturas", nonce)),
            minDeciC: mn,
            maxDeciC: mx,
            fromTs: T0 - 3600,
            toTs: T0 - 60,
            nonce: nonce
        });
    }

    /// Digest construido de forma independiente del contrato (verifica typehash y dominio).
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

    function _anchor(ColdChainRegistry.Readings memory r) internal {
        bytes memory sig = _sign(sensorKey, r);
        vm.prank(relayer);
        cold.anchorReadings(r, sig);
    }

    // ---------- Sensores ----------
    function test_OnlyActiveActorCanRegisterSensor() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.NotAuthorized.selector, stranger));
        cold.registerSensor(makeAddr("otro"));
    }

    function test_CannotRegisterSensorTwice() public {
        vm.prank(dist);
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.SensorAlreadyRegistered.selector, sensor));
        cold.registerSensor(sensor);
    }

    function test_OwnerCanRevoke_AndSensorCannotBeReRegistered() public {
        vm.prank(mfr);
        cold.revokeSensor(sensor);
        assertEq(cold.sensorOwner(sensor), address(0));

        vm.prank(dist);
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.SensorRevokedError.selector, sensor));
        cold.registerSensor(sensor);
    }

    function test_RegulatorCanRevoke() public {
        vm.prank(regulator);
        cold.revokeSensor(sensor);
        assertTrue(cold.revoked(sensor));
    }

    function test_StrangerCannotRevoke() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.NotAuthorized.selector, stranger));
        cold.revokeSensor(sensor);
    }

    function test_RevokedSensorCannotAnchor() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        bytes memory sig = _sign(sensorKey, r);
        vm.prank(mfr);
        cold.revokeSensor(sensor);
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.SensorNotRegistered.selector, sensor));
        cold.anchorReadings(r, sig);
    }

    // ---------- Anclaje ----------
    function test_AnchorValidReadings() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        bytes memory sig = _sign(sensorKey, r);

        vm.expectEmit(true, true, false, true);
        emit ColdChainRegistry.ReadingsAnchored(batchId, sensor, 0, r.readingsHash, 30, 60, r.fromTs, r.toTs);
        vm.prank(relayer); // quien envia no importa
        cold.anchorReadings(r, sig);

        assertEq(cold.nextNonce(sensor), 1);
        assertEq(cold.anchorCount(batchId), 1);
        assertEq(cold.excursionCount(batchId), 0);
    }

    function test_ExcursionIsAnchoredAndFlagged() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 95);
        bytes memory sig = _sign(sensorKey, r);
        vm.expectEmit(true, true, false, true);
        emit ColdChainRegistry.ColdChainExcursion(batchId, sensor, 30, 95);
        vm.prank(relayer);
        cold.anchorReadings(r, sig);
        assertEq(cold.anchorCount(batchId), 1);
        assertEq(cold.excursionCount(batchId), 1);
    }

    function test_ReplayOfSameSignatureReverts() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        bytes memory sig = _sign(sensorKey, r);
        vm.startPrank(relayer);
        cold.anchorReadings(r, sig);
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.InvalidNonce.selector, 1, 0));
        cold.anchorReadings(r, sig);
        vm.stopPrank();
    }

    function test_SkippedNonceReverts() public {
        ColdChainRegistry.Readings memory r = _r(5, 30, 60);
        bytes memory sig = _sign(sensorKey, r);
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.InvalidNonce.selector, 0, 5));
        cold.anchorReadings(r, sig);
    }

    function test_UnregisteredSignerReverts() public {
        (address rogue, uint256 rogueKey) = makeAddrAndKey("rogue");
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        bytes memory sig = _sign(rogueKey, r);
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.SensorNotRegistered.selector, rogue));
        cold.anchorReadings(r, sig);
    }

    function test_TamperedPayloadIsRejected() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        bytes memory sig = _sign(sensorKey, r);
        r.maxDeciC = 79; // alguien edita el contenido despues de firmado
        vm.expectRevert(); // recupera otra direccion: no es un sensor registrado
        cold.anchorReadings(r, sig);
    }

    function test_SignatureNotValidOnAnotherChain() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        bytes memory sig = _sign(sensorKey, r); // firmada para chainId 31337
        vm.chainId(1);
        vm.expectRevert();
        cold.anchorReadings(r, sig);
    }

    function test_GarbageSignatureReverts() public {
        vm.expectRevert(ColdChainRegistry.InvalidSignature.selector);
        cold.anchorReadings(_r(0, 30, 60), hex"1234");
    }

    function test_UnknownBatchReverts() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        r.batchId = keccak256("no existe");
        bytes memory sig = _sign(sensorKey, r);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.BatchNotFound.selector, r.batchId));
        cold.anchorReadings(r, sig);
    }

    function test_SensorOutsideCustodyReverts() public {
        _anchor(_r(0, 30, 60)); // con custodia: ok
        vm.prank(mfr);
        med.transferCustody(batchId, dist);

        ColdChainRegistry.Readings memory r = _r(1, 30, 60);
        bytes memory sig = _sign(sensorKey, r);
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.SensorNotInCustody.selector, batchId, sensor));
        cold.anchorReadings(r, sig);
    }

    function test_SuspendedOwnerBlocksItsSensors() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        bytes memory sig = _sign(sensorKey, r);
        vm.prank(regulator);
        actors.suspendActor(mfr, keccak256("sancion"));
        vm.expectRevert(abi.encodeWithSelector(ColdChainRegistry.NotAuthorized.selector, mfr));
        cold.anchorReadings(r, sig);
    }

    function test_FutureTimestampRejected() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        r.toTs = T0 + 1;
        bytes memory sig = _sign(sensorKey, r);
        vm.expectRevert(ColdChainRegistry.InvalidTimeWindow.selector);
        cold.anchorReadings(r, sig);
    }

    function test_InvertedWindowAndRangeRejected() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        r.fromTs = r.toTs;
        vm.expectRevert(ColdChainRegistry.InvalidTimeWindow.selector);
        cold.anchorReadings(r, hex"");

        r = _r(0, 60, 30);
        vm.expectRevert(ColdChainRegistry.InvalidRange.selector);
        cold.anchorReadings(r, hex"");
    }

    function test_ZeroReadingsHashRejected() public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        r.readingsHash = bytes32(0);
        vm.expectRevert(ColdChainRegistry.InvalidHash.selector);
        cold.anchorReadings(r, hex"");
    }

    function test_ContractDigestMatchesIndependentOne() public view {
        // Si esto falla, el typehash o el dominio del contrato difieren de lo que firmaria viem.
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        bytes memory sig = _sign(sensorKey, r);
        (bytes32 rr, bytes32 s, uint8 v) = (bytes32(0), bytes32(0), 0);
        assembly {
            rr := mload(add(sig, 32))
            s := mload(add(sig, 64))
            v := byte(0, mload(add(sig, 96)))
        }
        assertEq(ecrecover(cold.hashReadings(r), v, rr, s), sensor);
    }

    // ---------- Fuzz ----------
    function testFuzz_SequentialNonces(uint8 n) public {
        for (uint256 i = 0; i < n; i++) {
            _anchor(_r(i, 30, 60));
        }
        assertEq(cold.nextNonce(sensor), n);
        assertEq(cold.anchorCount(batchId), n);
    }

    function testFuzz_ExcursionIffOutOfRange(int16 mn, int16 mx) public {
        vm.assume(mn <= mx);
        _anchor(_r(0, mn, mx));
        bool expected = mn < 20 || mx > 80;
        assertEq(cold.excursionCount(batchId), expected ? 1 : 0);
    }

    function testFuzz_AnyoneCanRelayButNotForge(address relay, bytes32 junk) public {
        ColdChainRegistry.Readings memory r = _r(0, 30, 60);
        bytes memory sig = _sign(sensorKey, r);
        vm.prank(relay);
        cold.anchorReadings(r, sig);
        assertEq(cold.anchorCount(batchId), 1);

        // y una firma inventada nunca pasa
        ColdChainRegistry.Readings memory r2 = _r(1, 30, 60);
        vm.expectRevert();
        cold.anchorReadings(r2, abi.encodePacked(junk, junk, uint8(27)));
    }
}
