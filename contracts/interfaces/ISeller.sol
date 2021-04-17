// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface ISeller {
    function assetBalance(uint16 assetIndex_) external view returns(uint256);
    function updateBonus(uint16 assetIndex_, uint256 amount_) external;
}
