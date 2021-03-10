// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";


// This contract is owned by Timelock.
contract Guarantor is IGuarantor, Ownable {

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

    // who => assetIndex => amount
    mapping(address => mapping(uint256 => WithdrawRequest[])) public withdrawRequestMap;

    struct PoolInfo {
        uint256 weekOfPremium;
        uint256 weekOfBonus;
        uint256 accPremiumPerShare;
        uint256 accBonusPerShare;
    }

    mapping(uint256 => PoolInfo) public poolInfo;

    struct UserInfo {
        uint256 week;
        uint256 premium;
        uint256 bonus;
        uint256 accPremiumPerShare;
        uint256 accBonusPerShare;
    }

    mapping(address => mapping(uint256 => UserInfo)) public userInfo;

    // By user.
    mapping(address => mapping(uint256 => uint256)) public userBalance;
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) userLockedBalance;

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

    function getUserEffectiveBalance(address who, uint256 assetIndex_, uint256 week_) public view returns(uint256) {
        return userBalance[who][assetIndex_] + userLockedBalance[who][assetIndex_][week_];
    }

    function getAssetEffectiveBalance(uint256 assetIndex_, uint256 week_) public view returns(uint256) {
        return assetBalance[assetIndex_] + assetLockedBalance0[assetIndex_][week_];
    }

    function getBackedAssetBalance(uint256 assetIndex_, uint256 week_) public view returns(uint256) {
        return assetBalance[assetIndex_] + assetLockedBalance0[assetIndex_][week_] + assetLockedBalance1[assetIndex_][week_];
    }

    // Update and pay last week's premium.
    function updatePremium(uint256 assetIndex_, uint256 amount_) external {
        uint256 week = getWeekByTime(now).sub(1);

        IERC20(baseToken).safeTransferFrom(msg.sender, address(this), amount_);
        uint256 assetEffectiveBalance = getAssetEffectiveBalance(assetIndex_, week);
        poolInfo[assetIndex_].accPremiumPerShare = poolInfo[assetIndex_].accPremiumPerShare.add(
            amount_.mul(UNIT_PER_SHARE).div(assetEffectiveBalance));

        poolInfo[assetIndex_].weekOfPremium = week;
    }

    // Update and pay last week's bonus.
    function updateBonus(uint256 assetIndex_, uint256 amount_) external {
        uint256 week = getWeekByTime(now).sub(1);

        IERC20(tidalToken).safeTransferFrom(msg.sender, address(this), amount_);
        uint256 assetEffectiveBalance = getAssetEffectiveBalance(assetIndex_, week);
        poolInfo[assetIndex_].accBonusPerShare = poolInfo[assetIndex_].accBonusPerShare.add(
            amount_.mul(UNIT_PER_SHARE).div(assetEffectiveBalance));

        poolInfo[assetIndex_].weekOfBonus = week;
    }

    // Update user's last week's premium and bonus.
    function _updateUserPremiumAndBonus(address who_, uint256 assetIndex_) private {
        uint256 week = getWeekByTime(now).sub(1);

        // Return if premium or bonus not updated, or user already updated.
        if (userInfo[who_][assetIndex_].week > poolInfo[assetIndex_].weekOfPremium ||
                userInfo[who_][assetIndex_].week > poolInfo[assetIndex_].weekOfBonus ||
                userInfo[who_][assetIndex_].week >= week) {
            return;
        }

        uint256 userEffectiveBalance = getUserEffectiveBalance(who_, assetIndex_, week);

        // Update premium.
        userInfo[who_][assetIndex_].premium = userInfo[who_][assetIndex_].premium.add(userEffectiveBalance.mul(
            poolInfo[assetIndex_].accPremiumPerShare.sub(userInfo[who_][assetIndex_].accPremiumPerShare)).div(UNIT_PER_SHARE));
        userInfo[who_][assetIndex_].accPremiumPerShare = poolInfo[assetIndex_].accPremiumPerShare;

        // Update bonus.
        userInfo[who_][assetIndex_].bonus = userInfo[who_][assetIndex_].bonus.add(userEffectiveBalance.mul(
            poolInfo[assetIndex_].accBonusPerShare.sub(userInfo[who_][assetIndex_].accBonusPerShare)).div(UNIT_PER_SHARE));
        userInfo[who_][assetIndex_].accBonusPerShare = poolInfo[assetIndex_].accBonusPerShare;

        // Update week.
        userInfo[who_][assetIndex_].week = week;
    }

    function deposit(uint256 assetIndex_, uint256 amount_) external {
        _updateUserPremiumAndBonus(msg.sender, assetIndex_);

        address token = assetManager.getAssetToken(assetIndex_);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount_);

        assetBalance[assetIndex_] = assetBalance[assetIndex_].add(amount_);

        userBalance[msg.sender][assetIndex_] = userBalance[msg.sender][assetIndex_].add(amount_);
    }

    function withdraw(uint256 assetIndex_, uint256 amount_) external {
        require(amount_ > 0, "Requires positive amount");
        require(amount_ <= userBalance[msg.sender][assetIndex_], "Not enough user balance");

        _updateUserPremiumAndBonus(msg.sender, assetIndex_);

        WithdrawRequest memory request;
        request.amount = amount_;
        request.time = now;
        withdrawRequestMap[msg.sender][assetIndex_].push(request);

        uint256 currentWeek = getWeekByTime(now);
        uint256 nextWeek = currentWeek.add(1);

        assetBalance[assetIndex_] = assetBalance[assetIndex_].sub(amount_);
        assetLockedBalance0[assetIndex_][currentWeek] = assetLockedBalance0[assetIndex_][currentWeek].add(amount_);
        assetLockedBalance1[assetIndex_][nextWeek] = assetLockedBalance1[assetIndex_][nextWeek].add(amount_);

        userBalance[msg.sender][assetIndex_] = userBalance[msg.sender][assetIndex_].sub(amount_);
        userLockedBalance[msg.sender][assetIndex_][currentWeek] = userLockedBalance[msg.sender][assetIndex_][currentWeek].add(amount_);
    }

    function withdrawReady(uint256 assetIndex_, uint256 requestIndex_) external {
        WithdrawRequest storage request = withdrawRequestMap[msg.sender][assetIndex_][requestIndex_];
        uint256 unlockTime = getUnlockTime(request.time);

        require(now > unlockTime, "Not ready to withdraw yet");

        address token = assetManager.getAssetToken(assetIndex_);
        IERC20(token).safeTransfer(msg.sender, request.amount);

        // Now remove the request, simplely set the amount to 0.
        request.amount = 0;
    }

    function claimPremium(uint256 assetIndex_) external {
        IERC20(baseToken).safeTransfer(msg.sender, userInfo[msg.sender][assetIndex_].premium);
        userInfo[msg.sender][assetIndex_].premium = 0;
    }

    function claimBonus(uint256 assetIndex_) external {
        IERC20(tidalToken).safeTransfer(msg.sender, userInfo[msg.sender][assetIndex_].bonus);
        userInfo[msg.sender][assetIndex_].bonus = 0;
    }
}
