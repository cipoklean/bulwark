// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BulwarkVault} from "./BulwarkVault.sol";

/// @title BulwarkFactory
/// @notice Creates one vault per user and keeps the public list keepers scan.
contract BulwarkFactory {
    address public immutable borrowerOps;
    address public immutable troveManager;
    address public immutable priceFeed;
    address public immutable musd;

    address[] public vaults;
    mapping(address => address) public vaultOf;

    event VaultCreated(address indexed owner, address vault);

    constructor(address _borrowerOps, address _troveManager, address _priceFeed, address _musd) {
        borrowerOps = _borrowerOps;
        troveManager = _troveManager;
        priceFeed = _priceFeed;
        musd = _musd;
    }

    function createVault() external returns (address vault) {
        require(vaultOf[msg.sender] == address(0), "vault exists");
        vault = address(new BulwarkVault(msg.sender, borrowerOps, troveManager, priceFeed, musd));
        vaultOf[msg.sender] = vault;
        vaults.push(vault);
        emit VaultCreated(msg.sender, vault);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    function allVaults() external view returns (address[] memory) {
        return vaults;
    }
}
