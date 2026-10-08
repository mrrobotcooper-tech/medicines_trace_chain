// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ActorRegistry} from "../src/ActorRegistry.sol";
import {MedicineRegistry} from "../src/MedicineRegistry.sol";
import {IActorRegistry, ActorType} from "../src/interfaces/IActorRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract PharmaTraceTest is Test {
    ActorRegistry actors;
    MedicineRegistry reg;

    address admin = makeAddr("regulator");
    address mfr = makeAddr("laboratorio");
    address dist = makeAddr("drogueria");
    address pharm = makeAddr("farmacia");
    address pharm2 = makeAddr("farmaciaSinLicencia");
    address stranger = makeAddr("stranger");

    uint64 constant T0 = 1_700_000_000;
    bytes32 constant PRODUCT = keccak256("07791234567890"); // GTIN de ejemplo
    bytes32 constant LOT = keccak256("LOTE-A001");

    bytes32[4] serials;
    bytes32[4] leaves;
    bytes32 n01;
    bytes32 n23;
    bytes32 root;

    function setUp() public {
        vm.warp(T0);

        vm.startPrank(admin);
        actors = new ActorRegistry(admin);
        actors.grantRole(actors.REGULATOR_ROLE(), admin);
        reg = new MedicineRegistry(IActorRegistry(address(actors)));
        actors.licenseActor(mfr, ActorType.Manufacturer, T0 + 365 days);
        actors.licenseActor(dist, ActorType.Distributor, T0 + 365 days);
        actors.licenseActor(pharm, ActorType.Pharmacy, T0 + 365 days);
        vm.stopPrank();

        for (uint256 i = 0; i < 4; i++) {
            serials[i] = keccak256(abi.encode("SN", i));
            leaves[i] = keccak256(abi.encodePacked(serials[i]));
        }
        n01 = _pair(leaves[0], leaves[1]);
        n23 = _pair(leaves[2], leaves[3]);
        root = _pair(n01, n23);
    }

    // ---------- helpers ----------
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

    function _register(bytes32 lot, uint64 expiry) internal returns (bytes32) {
        vm.prank(mfr);
        return reg.registerBatch(PRODUCT, lot, root, expiry);
    }

    function _toPharmacy(bytes32 lot, uint64 expiry) internal returns (bytes32 id) {
        id = _register(lot, expiry);
        vm.prank(mfr);
        reg.transferCustody(id, dist);
        vm.prank(dist);
        reg.transferCustody(id, pharm);
    }

    // ---------- ActorRegistry ----------
    function test_OnlyRegulatorCanLicense() public {
        bytes32 role = actors.REGULATOR_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, role)
        );
        actors.licenseActor(stranger, ActorType.Pharmacy, T0 + 10 days);
    }

    function test_ExpiredLicenseIsInactive() public {
        vm.warp(T0 + 366 days);
        assertEq(uint8(actors.activeTypeOf(mfr)), uint8(ActorType.None));
    }

    function test_SuspendedActorIsInactiveAndReinstated() public {
        vm.startPrank(admin);
        actors.suspendActor(pharm, keccak256("inspeccion"));
        assertEq(uint8(actors.activeTypeOf(pharm)), uint8(ActorType.None));
        actors.reinstateActor(pharm);
        vm.stopPrank();
        assertEq(uint8(actors.activeTypeOf(pharm)), uint8(ActorType.Pharmacy));
    }

    // ---------- Registro de lotes ----------
    function test_OnlyActiveManufacturerCanRegister() public {
        vm.prank(pharm);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.NotAuthorized.selector, pharm));
        reg.registerBatch(PRODUCT, LOT, root, T0 + 100 days);
    }

    function test_DuplicateBatchRejected() public {
        bytes32 id = _register(LOT, T0 + 100 days);
        vm.prank(mfr);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.BatchAlreadyExists.selector, id));
        reg.registerBatch(PRODUCT, LOT, root, T0 + 100 days);
    }

    function test_PastExpiryRejected() public {
        vm.prank(mfr);
        vm.expectRevert(MedicineRegistry.InvalidExpiry.selector);
        reg.registerBatch(PRODUCT, LOT, root, T0);
    }

    function test_ZeroHashRejected() public {
        vm.prank(mfr);
        vm.expectRevert(MedicineRegistry.InvalidHash.selector);
        reg.registerBatch(PRODUCT, LOT, bytes32(0), T0 + 100 days);
    }

    // ---------- Cadena de custodia ----------
    function test_FullChainAndDispense() public {
        bytes32 id = _toPharmacy(LOT, T0 + 300 days);
        assertEq(reg.getBatch(id).custodian, pharm);

        vm.expectEmit(true, true, true, true);
        emit MedicineRegistry.UnitDispensed(id, serials[0], pharm);
        vm.prank(pharm);
        reg.dispense(id, serials[0], _proofFor(0));

        assertTrue(reg.isDispensed(id, serials[0]));
        assertFalse(reg.isDispensed(id, serials[1]));
    }

    function test_OnlyCustodianCanTransfer() public {
        bytes32 id = _register(LOT, T0 + 300 days);
        vm.prank(dist);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.NotCustodian.selector, id, dist));
        reg.transferCustody(id, pharm);
    }

    function test_CannotTransferToUnlicensed() public {
        bytes32 id = _register(LOT, T0 + 300 days);
        vm.prank(mfr);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.InvalidReceiver.selector, pharm2));
        reg.transferCustody(id, pharm2);
    }

    function test_CannotTransferBackToManufacturer() public {
        bytes32 id = _register(LOT, T0 + 300 days);
        vm.prank(mfr);
        reg.transferCustody(id, dist);
        vm.prank(dist);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.InvalidReceiver.selector, mfr));
        reg.transferCustody(id, mfr);
    }

    function test_PharmacyCustodyIsFinal() public {
        bytes32 id = _toPharmacy(LOT, T0 + 300 days);
        vm.prank(pharm);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.FinalCustody.selector, id));
        reg.transferCustody(id, dist);
    }

    function test_SuspendedCustodianCannotShip() public {
        bytes32 id = _register(LOT, T0 + 300 days);
        vm.prank(admin);
        actors.suspendActor(mfr, keccak256("sancion"));
        vm.prank(mfr);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.NotAuthorized.selector, mfr));
        reg.transferCustody(id, dist);
    }

    // ---------- Dispensa / antifalsificacion ----------
    function test_DispenseTwiceReverts() public {
        bytes32 id = _toPharmacy(LOT, T0 + 300 days);
        vm.startPrank(pharm);
        reg.dispense(id, serials[1], _proofFor(1));
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.AlreadyDispensed.selector, id, serials[1]));
        reg.dispense(id, serials[1], _proofFor(1));
        vm.stopPrank();
    }

    function test_CounterfeitSerialReverts() public {
        bytes32 id = _toPharmacy(LOT, T0 + 300 days);
        bytes32 fake = keccak256("SN-FALSIFICADO");
        vm.prank(pharm);
        vm.expectRevert(MedicineRegistry.InvalidProof.selector);
        reg.dispense(id, fake, _proofFor(0));
    }

    function test_ProofOfAnotherSerialDoesNotWork() public {
        bytes32 id = _toPharmacy(LOT, T0 + 300 days);
        vm.prank(pharm);
        vm.expectRevert(MedicineRegistry.InvalidProof.selector);
        reg.dispense(id, serials[0], _proofFor(1));
    }

    function test_OnlyCurrentPharmacyCanDispense() public {
        bytes32 id = _register(LOT, T0 + 300 days); // aun en custodia del laboratorio
        vm.prank(pharm);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.NotCustodian.selector, id, pharm));
        reg.dispense(id, serials[0], _proofFor(0));
    }

    function test_ExpiredBatchCannotBeDispensed() public {
        bytes32 id = _toPharmacy(LOT, T0 + 30 days);
        vm.warp(T0 + 31 days);
        vm.prank(pharm);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.BatchExpired.selector, id));
        reg.dispense(id, serials[0], _proofFor(0));
    }

    // ---------- Recall ----------
    function test_RegulatorRecallBlocksEverything() public {
        bytes32 id = _toPharmacy(LOT, T0 + 300 days);
        vm.prank(admin);
        reg.recallBatch(id, keccak256("contaminacion"));

        vm.prank(pharm);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.BatchRecalledError.selector, id));
        reg.dispense(id, serials[0], _proofFor(0));
    }

    function test_ManufacturerCanRecallEvenWithExpiredLicense() public {
        bytes32 id = _register(LOT, T0 + 700 days);
        vm.warp(T0 + 400 days); // licencia del laboratorio vencida
        vm.prank(mfr);
        reg.recallBatch(id, keccak256("lote defectuoso"));
        assertEq(uint8(reg.getBatch(id).status), uint8(MedicineRegistry.BatchStatus.Recalled));
    }

    function test_StrangerCannotRecall() public {
        bytes32 id = _register(LOT, T0 + 300 days);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.NotAuthorized.selector, stranger));
        reg.recallBatch(id, keccak256("x"));
    }

    function test_RecallTwiceReverts() public {
        bytes32 id = _register(LOT, T0 + 300 days);
        vm.startPrank(mfr);
        reg.recallBatch(id, keccak256("a"));
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.BatchRecalledError.selector, id));
        reg.recallBatch(id, keccak256("b"));
        vm.stopPrank();
    }

    // ---------- verifyUnit (lectura publica) ----------
    function test_VerifyUnitResults() public {
        bytes32 unknown = keccak256("no existe");
        assertEq(uint8(reg.verifyUnit(unknown, serials[0], _proofFor(0))), uint8(MedicineRegistry.VerifyResult.UnknownBatch));

        bytes32 id = _toPharmacy(LOT, T0 + 300 days);
        assertEq(uint8(reg.verifyUnit(id, serials[0], _proofFor(0))), uint8(MedicineRegistry.VerifyResult.Valid));
        assertEq(uint8(reg.verifyUnit(id, keccak256("fake"), _proofFor(0))), uint8(MedicineRegistry.VerifyResult.InvalidProof));

        vm.prank(pharm);
        reg.dispense(id, serials[0], _proofFor(0));
        assertEq(uint8(reg.verifyUnit(id, serials[0], _proofFor(0))), uint8(MedicineRegistry.VerifyResult.AlreadyDispensed));

        vm.prank(admin);
        reg.recallBatch(id, keccak256("r"));
        assertEq(uint8(reg.verifyUnit(id, serials[2], _proofFor(2))), uint8(MedicineRegistry.VerifyResult.Recalled));
    }

    function test_VerifyUnitExpired() public {
        bytes32 id = _register(LOT, T0 + 30 days);
        vm.warp(T0 + 31 days);
        assertEq(uint8(reg.verifyUnit(id, serials[0], _proofFor(0))), uint8(MedicineRegistry.VerifyResult.Expired));
    }

    // ---------- Fuzz ----------
    function testFuzz_UnknownSerialNeverVerifies(bytes32 serial) public {
        for (uint256 i = 0; i < 4; i++) {
            vm.assume(serial != serials[i]);
        }
        bytes32 id = _toPharmacy(LOT, T0 + 300 days);
        assertEq(uint8(reg.verifyUnit(id, serial, _proofFor(0))), uint8(MedicineRegistry.VerifyResult.InvalidProof));
        vm.prank(pharm);
        vm.expectRevert(MedicineRegistry.InvalidProof.selector);
        reg.dispense(id, serial, _proofFor(0));
    }

    function testFuzz_StrangerCannotRegisterBatch(address who) public {
        vm.assume(who != mfr);
        vm.prank(who);
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.NotAuthorized.selector, who));
        reg.registerBatch(PRODUCT, LOT, root, T0 + 100 days);
    }

    function testFuzz_PastOrCurrentExpiryRejected(uint64 expiry) public {
        expiry = uint64(bound(expiry, 0, T0));
        vm.prank(mfr);
        vm.expectRevert(MedicineRegistry.InvalidExpiry.selector);
        reg.registerBatch(PRODUCT, LOT, root, expiry);
    }

    function testFuzz_EachSerialDispensesOnlyOnce(uint8 idx) public {
        uint256 i = bound(idx, 0, 3);
        bytes32 id = _toPharmacy(LOT, T0 + 300 days);
        vm.startPrank(pharm);
        reg.dispense(id, serials[i], _proofFor(i));
        vm.expectRevert(abi.encodeWithSelector(MedicineRegistry.AlreadyDispensed.selector, id, serials[i]));
        reg.dispense(id, serials[i], _proofFor(i));
        vm.stopPrank();
    }
}
