// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/ISeller.sol";


// This contract is owned by Timelock.
contract Seller is ISeller, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // The computing ability of EVM is limited, so we cap the maximum number of iterations
    // at 100. If the gap is larger, just compute multiple times.
    uint256 constant MAXIMUM_ITERATION = 100;

    // For improving precision of accPremiumPerShare and accBonusPerShare.
    uint256 constant UNIT_PER_SHARE = 1e18;

    IBuyer public buyer;
    IAssetManager public assetManager;
    IERC20 public baseToken;  // By default it's USDC
    IERC20 public tidalToken;

    struct WithdrawRequest {
        uint256 amount;
        uint256 time;
    }

    // who => category => amount
    mapping(address => mapping(uint8 => WithdrawRequest[])) public withdrawRequestMap;

    mapping(address => mapping(uint256 => bool)) public outOfBasket;

    struct PoolInfo {
        uint256 weekOfPremium;
        uint256 weekOfBonus;
        uint256 accPremiumPerShare;
        uint256 accBonusPerShare;
    }

    mapping(uint8 => PoolInfo) public poolInfo;

    struct UserInfo {
        uint256 week;
        uint256 premium;
        uint256 bonus;
        uint256 accPremiumPerShare;
        uint256 accBonusPerShare;
    }

    mapping(address => mapping(uint8 => UserInfo)) public userInfo;

    // By user.
    mapping(address => mapping(uint8 => uint256)) public userBalance;
    mapping(address => mapping(uint8 => mapping(uint256 => uint256))) userLockedBalance;

    // By category.
    mapping(uint8 => uint256) public categoryBalance;
    mapping(uint8 => mapping(uint256 => uint256)) public categoryLockedBalance;

    // Balance here not withdrawn yet, and are good for staking bonus.
    // assetIndex => amount
    mapping(uint256 => uint256) public assetBalance;

    // Balance here are to be withdrawn, but are still good for staking bonus.
    // assetIndex => week => amount
    mapping(uint256 => mapping(uint256 => uint256)) public assetLockedBalance0;

    // Balance here are not good for staking bonus.
    // assetIndex => week => amount
    mapping(uint256 => mapping(uint256 => uint256)) public assetLockedBalance1;

    constructor (IBuyer buyer_, IAssetManager assetManager_, IERC20 baseToken_, IERC20 tidalToken_) public {
        buyer = buyer_;
        assetManager = assetManager_;
        baseToken = baseToken_;
        tidalToken = tidalToken_;
    }

    function getWeekByTime(uint256 time_) public pure returns(uint256) {
        return time_ / (7 days);
    }

    function getUnlockTime(uint256 time_) public pure returns(uint256) {
        return (time_ / (7 days) + 2) * (7 days);
    }

    function getUserEffectiveBalance(address who, uint8 category_, uint256 week_) public view returns(uint256) {
        return userBalance[who][category_] + userLockedBalance[who][category_][week_];
    }

    function getCategoryEffectiveBalance(uint8 category_, uint256 week_) public view returns(uint256) {
        return categoryBalance[category_] + categoryLockedBalance[category_][week_];
    }

    function getBackedAssetBalance(uint8 assetIndex_, uint256 week_) public view returns(uint256) {
        return assetBalance[assetIndex_] + assetLockedBalance0[assetIndex_][week_] + assetLockedBalance1[assetIndex_][week_];
    }

    // Update and pay last week's premium.
    function updatePremium(uint8 category_, uint256 amount_) external {
        uint256 week = getWeekByTime(now).sub(1);

        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount_);
        uint256 categoryEffectiveBalance = getCategoryEffectiveBalance(category_, week);
        poolInfo[category_].accPremiumPerShare = poolInfo[category_].accPremiumPerShare.add(
            amount_.mul(UNIT_PER_SHARE).div(categoryEffectiveBalance));

        poolInfo[category_].weekOfPremium = week;
    }

    // Update and pay last week's bonus.
    function updateBonus(uint8 category_, uint256 amount_) external {
        uint256 week = getWeekByTime(now).sub(1);

        IERC20(tidalToken).safeTransferFrom(msg.sender, address(this), amount_);
        uint256 categoryEffectiveBalance = getCategoryEffectiveBalance(category_, week);
        poolInfo[category_].accBonusPerShare = poolInfo[category_].accBonusPerShare.add(
            amount_.mul(UNIT_PER_SHARE).div(categoryEffectiveBalance));

        poolInfo[category_].weekOfBonus = week;
    }

    // Update user's last week's premium and bonus.
    function _updateUserPremiumAndBonus(address who_, uint8 category_) private {
        uint256 week = getWeekByTime(now).sub(1);

        // Return if premium or bonus not updated, or user already updated.
        if (userInfo[who_][category_].week > poolInfo[category_].weekOfPremium ||
                userInfo[who_][category_].week > poolInfo[category_].weekOfBonus ||
                userInfo[who_][category_].week >= week) {
            return;
        }

        uint256 userEffectiveBalance = getUserEffectiveBalance(who_, category_, week);

        // Update premium.
        userInfo[who_][category_].premium = userInfo[who_][category_].premium.add(userEffectiveBalance.mul(
            poolInfo[category_].accPremiumPerShare.sub(userInfo[who_][category_].accPremiumPerShare)).div(UNIT_PER_SHARE));
        userInfo[who_][category_].accPremiumPerShare = poolInfo[category_].accPremiumPerShare;

        // Update bonus.
        userInfo[who_][category_].bonus = userInfo[who_][category_].bonus.add(userEffectiveBalance.mul(
            poolInfo[category_].accBonusPerShare.sub(userInfo[who_][category_].accBonusPerShare)).div(UNIT_PER_SHARE));
        userInfo[who_][category_].accBonusPerShare = poolInfo[category_].accBonusPerShare;

        // Update week.
        userInfo[who_][category_].week = week;
    }

    function deposit(uint8 category_, uint256 amount_) external {
        _updateUserPremiumAndBonus(msg.sender, category_);

        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount_);

        for (uint256 i = 0; i < assetManager.getIndexesByCategoryLength(category_); ++i) {
            uint256 index = assetManager.getIndexesByCategory(category_, i);
            assetBalance[index] = assetBalance[index].add(amount_);
        }

        userBalance[msg.sender][category_] = userBalance[msg.sender][category_].add(amount_);
    }

    function withdraw(uint8 category_, uint256 amount_) external {
        require(amount_ > 0, "Requires positive amount");
        require(amount_ <= userBalance[msg.sender][category_], "Not enough user balance");

        _updateUserPremiumAndBonus(msg.sender, category_);

        WithdrawRequest memory request;
        request.amount = amount_;
        request.time = now;
        withdrawRequestMap[msg.sender][category_].push(request);

        uint256 currentWeek = getWeekByTime(now);
        uint256 nextWeek = currentWeek.add(1);

        for (uint256 i = 0; i < assetManager.getIndexesByCategoryLength(category_); ++i) {
            uint256 index = assetManager.getIndexesByCategory(category_, i);

            // Only process assets in my basket.
            if (!outOfBasket[msg.sender][index]) {
                assetBalance[index] = assetBalance[index].sub(amount_);
                assetLockedBalance0[index][currentWeek] = assetLockedBalance0[index][currentWeek].add(amount_);
                assetLockedBalance1[index][nextWeek] = assetLockedBalance1[index][nextWeek].add(amount_);
            }
        }

        userBalance[msg.sender][category_] = userBalance[msg.sender][category_].sub(amount_);
        userLockedBalance[msg.sender][category_][currentWeek] = userLockedBalance[msg.sender][category_][currentWeek].add(amount_);

        categoryBalance[category_] = categoryBalance[category_].sub(amount_);
        categoryLockedBalance[category_][currentWeek] = categoryLockedBalance[category_][currentWeek].add(amount_);
    }

    function withdrawReady(uint8 category_, uint256 requestIndex_) external {
        WithdrawRequest storage request = withdrawRequestMap[msg.sender][category_][requestIndex_];
        uint256 unlockTime = getUnlockTime(request.time);

        require(now > request.time, "Not ready to withdraw yet");

        IERC20(baseToken).safeTransfer(msg.sender, request.amount);

        // Now remove the request, simplely set the amount to 0.
        request.amount = 0;
    }

    function claimPremium(uint8 category_) external {
        IERC20(baseToken).safeTransfer(msg.sender, userInfo[msg.sender][category_].premium);
        userInfo[msg.sender][category_].premium = 0;
    }

    function claimBonus(uint8 category_) external {
        IERC20(baseToken).safeTransfer(msg.sender, userInfo[msg.sender][category_].bonus);
        userInfo[msg.sender][category_].bonus = 0;
    }
}
