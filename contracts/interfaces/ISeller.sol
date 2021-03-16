// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface ISeller {
    function assetBalance(uint256 assetIndex_) external view returns(uint256);
    function updateBonus(uint8 category_, uint256 amount_) external;
}
