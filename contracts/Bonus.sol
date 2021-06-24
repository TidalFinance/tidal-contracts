// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import "./common/WeekManaged.sol";

import "./interfaces/IBonus.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/IRegistry.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Bonus is IBonus, Ownable, WeekManaged {

    IRegistry public registry;

    mapping(uint16 => uint256) public bonusPerAssetOfG;
    mapping(uint16 => uint256) public bonusPerAssetOfS;

    // assetIndex => week
    mapping(uint16 => uint256) public sellerWeek;
    // assetIndex => week
    mapping(uint16 => uint256) public guarantorWeek;

    constructor (IRegistry registry_) public {
        registry = registry_;
    }

    function _timeExtra() internal override view returns(uint256) {
        return registry.timeExtra();
    }

    function setBonusPerAssetOfG(uint16 assetIndex_, uint256 value_) external onlyOwner {
        bonusPerAssetOfG[assetIndex_] = value_;
    }

    function setBonusPerAssetOfS(uint16 assetIndex_, uint256 value_) external onlyOwner {
        bonusPerAssetOfS[assetIndex_] = value_;
    }

    function updateSellerBonus(uint16 assetIndex_) external {
        uint256 currentWeek = getCurrentWeek();
        require(sellerWeek[assetIndex_] < currentWeek, "Already updated");

        IERC20(registry.tidalToken()).approve(registry.seller(), bonusPerAssetOfS[assetIndex_]);
        ISeller(registry.seller()).updateBonus(assetIndex_, bonusPerAssetOfS[assetIndex_]);

        sellerWeek[assetIndex_] = currentWeek;
    }

    function updateGuarantorBonus(uint16 assetIndex_) external {
        uint256 currentWeek = getCurrentWeek();
        require(guarantorWeek[assetIndex_] < currentWeek, "Already updated");

        IERC20(registry.tidalToken()).approve(registry.guarantor(), bonusPerAssetOfG[assetIndex_]);
        IGuarantor(registry.guarantor()).updateBonus(assetIndex_, bonusPerAssetOfG[assetIndex_]);

        guarantorWeek[assetIndex_] = currentWeek;
    }
}
