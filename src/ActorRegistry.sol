// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IActorRegistry, ActorType} from "./interfaces/IActorRegistry.sol";

/// @notice Padron de actores habilitados (laboratorios, droguerias, farmacias).
/// @dev Representa la identidad INSTITUCIONAL: quien esta licenciado y hasta cuando.
///      Esta demo NO es un sistema oficial ni reemplaza a un regulador real: el
///      REGULATOR_ROLE modela a la autoridad que habilita actores.
///      No se guardan datos personales ni razon social on-chain, solo address + tipo + vigencia.
contract ActorRegistry is AccessControl, IActorRegistry {
    bytes32 public constant REGULATOR_ROLE = keccak256("REGULATOR_ROLE");

    struct Actor {
        ActorType actorType;
        uint64 licenseExpiry;
        bool suspended;
    }

    mapping(address account => Actor) private _actors;

    event ActorLicensed(address indexed account, ActorType actorType, uint64 licenseExpiry);
    event ActorSuspended(address indexed account, bytes32 reasonHash);
    event ActorReinstated(address indexed account);

    error InvalidActor();
    error InvalidExpiry();
    error ActorUnknown(address account);

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @dev Tambien sirve para renovar. Re-licenciar NO levanta una suspension.
    function licenseActor(address account, ActorType actorType, uint64 licenseExpiry)
        external
        onlyRole(REGULATOR_ROLE)
    {
        if (account == address(0) || actorType == ActorType.None) revert InvalidActor();
        if (licenseExpiry <= block.timestamp) revert InvalidExpiry();
        _actors[account] =
            Actor({actorType: actorType, licenseExpiry: licenseExpiry, suspended: _actors[account].suspended});
        emit ActorLicensed(account, actorType, licenseExpiry);
    }

    function suspendActor(address account, bytes32 reasonHash) external onlyRole(REGULATOR_ROLE) {
        if (_actors[account].actorType == ActorType.None) revert ActorUnknown(account);
        _actors[account].suspended = true;
        emit ActorSuspended(account, reasonHash);
    }

    function reinstateActor(address account) external onlyRole(REGULATOR_ROLE) {
        if (_actors[account].actorType == ActorType.None) revert ActorUnknown(account);
        _actors[account].suspended = false;
        emit ActorReinstated(account);
    }

    function activeTypeOf(address account) public view returns (ActorType) {
        Actor memory a = _actors[account];
        if (a.suspended || a.licenseExpiry < block.timestamp) return ActorType.None;
        return a.actorType;
    }

    function isRegulator(address account) external view returns (bool) {
        return hasRole(REGULATOR_ROLE, account);
    }

    function getActor(address account) external view returns (Actor memory) {
        return _actors[account];
    }
}
