// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IBorrowerOperations {
    function openTrove(uint256 debtAmount, address upperHint, address lowerHint) external payable;
    function repayMUSD(uint256 amount, address upperHint, address lowerHint) external;
    function addColl(address upperHint, address lowerHint) external payable;
    function closeTrove() external;
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

/// @notice Throwaway contract for the kill-gate test: can a contract own a Mezo trove
/// and repay it from MUSD it holds?
contract GateVault {
    IBorrowerOperations public immutable bo;
    IERC20Min public immutable musd;
    address public immutable owner;

    constructor(address _bo, address _musd) {
        bo = IBorrowerOperations(_bo);
        musd = IERC20Min(_musd);
        owner = msg.sender;
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    function open(uint256 debtAmount, address upperHint, address lowerHint) external payable onlyOwner {
        bo.openTrove{value: msg.value}(debtAmount, upperHint, lowerHint);
    }

    /// Repays from MUSD this contract already holds (the "reserve").
    function repayFromReserve(uint256 amount, address upperHint, address lowerHint) external {
        bo.repayMUSD(amount, upperHint, lowerHint);
    }

    function topUp(address upperHint, address lowerHint) external payable {
        bo.addColl{value: msg.value}(upperHint, lowerHint);
    }

    function close() external onlyOwner {
        bo.closeTrove();
    }

    function sweep(address to) external onlyOwner {
        musd.transfer(to, musd.balanceOf(address(this)));
        (bool ok,) = to.call{value: address(this).balance}("");
        require(ok, "btc send failed");
    }

    receive() external payable {}
}
