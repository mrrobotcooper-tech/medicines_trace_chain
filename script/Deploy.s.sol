// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ActorRegistry} from "../src/ActorRegistry.sol";
import {MedicineRegistry} from "../src/MedicineRegistry.sol";
import {IActorRegistry} from "../src/interfaces/IActorRegistry.sol";

/// @dev La cuenta que firma llega por CLI (--unlocked --sender en Anvil, o --account con keystore).
contract Deploy is Script {
    function run() external {
        vm.startBroadcast();
        address deployer = msg.sender;

        ActorRegistry actors = new ActorRegistry(deployer);
        actors.grantRole(actors.REGULATOR_ROLE(), deployer);
        MedicineRegistry reg = new MedicineRegistry(IActorRegistry(address(actors)));
        vm.stopBroadcast();

        console.log("ActorRegistry    :", address(actors));
        console.log("MedicineRegistry :", address(reg));
    }
}
