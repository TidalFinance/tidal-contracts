// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./WeekManaged.sol";

import "./interfaces/IBonus.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Bonus is IBonus, Ownable, WeekManaged {

    IRegistry public registry;

    uint256 public bonusPerAssetOfG = 500e18;
    uint256 public bonusPerAssetOfS = 3500e18;

    // assetIndex => week
    mapping(uint16 => uint256) public sellerWeek;
    // assetIndex => week
    mapping(uint16 => uint256) public guarantorWeek;

    constructor () public { }

    function setRegistry(IRegistry registry_) external onlyOwner {
        registry = registry_;
    }

    function setBonusPerAssetOfG(uint256 value_) external onlyOwner {
        bonusPerAssetOfG = value_;
    }

    function setBonusPerAssetOfS(uint256 value_) external onlyOwner {
        bonusPerAssetOfS = value_;
    }

    function updateSellerBonus(uint16 assetIndex_) external {
        uint256 currentWeek = getCurrentWeek();
        require(sellerWeek[assetIndex_] < currentWeek, "Already updated");

        IERC20(registry.tidalToken()).approve(registry.seller(), bonusPerAssetOfS);
        ISeller(registry.seller()).updateBonus(assetIndex_, bonusPerAssetOfS);

        sellerWeek[assetIndex_] = currentWeek;
    }

    function updateGuarantorBonus(uint16 assetIndex_) external {
        uint256 currentWeek = getCurrentWeek();
        require(guarantorWeek[assetIndex_] < currentWeek, "Already updated");

        IERC20(registry.tidalToken()).approve(registry.guarantor(), bonusPerAssetOfG);
        IGuarantor(registry.guarantor()).updateBonus(assetIndex_, bonusPerAssetOfG);

        guarantorWeek[assetIndex_] = currentWeek;
    }
}
