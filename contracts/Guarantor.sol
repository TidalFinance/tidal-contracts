// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBonus.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";


// This contract is owned by Timelock.
contract Guarantor is IGuarantor, Ownable {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // The computing ability of EVM is limited, so we cap the maximum number of iterations
    // at 100. If the gap is larger, just compute multiple times.
    uint256 constant MAXIMUM_ITERATION = 100;

    // For improving precision of premiumPerShare and bonusPerShare.
    uint256 constant UNIT_PER_SHARE = 1e18;

    IBonus public bonus;
    IBuyer public buyer;
    IAssetManager public assetManager;
    IERC20 public baseToken;  // By default it's USDC
    IERC20 public tidalToken;

    struct WithdrawRequest {
        uint256 assetIndex;
        uint256 amount;
        uint256 time;
        bool executed;
    }

    // who => WithdrawRequest[]
    mapping(address => WithdrawRequest[]) public withdrawRequestMap;

    struct PoolInfo {
        uint256 weekOfPremium;
        uint256 weekOfBonus;
        uint256 premiumPerShare;
        uint256 bonusPerShare;
    }

    mapping(uint256 => PoolInfo) public poolInfo;

    struct UserBalance {
        uint256 currentBalance;
        uint256 futureBalance;
    }

    mapping(address => mapping(uint256 => UserBalance)) public userBalance;

    struct UserInfo {
        uint256 week;
        uint256 premium;
        uint256 bonus;
    }

    mapping(address => UserInfo) public userInfo;

    // Balance here not withdrawn yet, and are good for staking bonus.
    // assetIndex => amount
    mapping(uint256 => uint256) public assetBalance;

    struct PayoutInfo {
        address toAddress;
        uint256 total;
        uint256 unitPerShare;
        uint256 paid;
        bool finished;
    }

    // payoutId => PayoutInfo
    mapping(uint256 => PayoutInfo) public payoutInfo;

    // assetIndex => payoutId
    mapping(uint256 => uint256) public payoutIdMap;

    // who => assetIndex => payoutId
    mapping(address => mapping(uint256 => uint256)) userPayoutIdMap;

    constructor () public { }

    function setBaseToken(IERC20 baseToken_) external onlyOwner {
        baseToken = baseToken_;
    }

    function setTidalToken(IERC20 tidalToken_) external onlyOwner {
        tidalToken = tidalToken_;
    }

    function setAssetManager(IAssetManager assetManager_) external onlyOwner {
        assetManager = assetManager_;
    }

    function setBuyer(IBuyer buyer_) external onlyOwner {
        buyer = buyer_;
    }

    function setBonus(IBonus bonus_) external onlyOwner {
        bonus = bonus_;
    }

    function getWeekByTime(uint256 time_) public pure returns(uint256) {
        return time_ / (7 days);
    }

    function getWithdrawTime(uint256 time_) public pure returns(uint256) {
        return (time_ / (7 days) + 2) * (7 days);
    }

    // Update and pay last week's premium.
    function updatePremium(uint256 assetIndex_) external {
        uint256 week = getWeekByTime(now);
        require(buyer.weekToUpdate() == week, "buyer not ready");
        require(poolInfo[assetIndex_].weekOfPremium < week, "already updated");

        uint256 amount = buyer.premiumForGuarantor(assetIndex_);

        if (assetBalance[assetIndex_] > 0) {
            IERC20(baseToken).safeTransferFrom(address(buyer), address(this), amount);
            poolInfo[assetIndex_].premiumPerShare =
                amount.mul(UNIT_PER_SHARE).div(assetBalance[assetIndex_]);
        }

        poolInfo[assetIndex_].weekOfPremium = week;
    }

    // Update and pay last week's bonus.
    function updateBonus(uint256 assetIndex_, uint256 amount_) external override {
        require(msg.sender == address(bonus), "Only Bonus can call");

        uint256 week = getWeekByTime(now);

        require(poolInfo[assetIndex_].weekOfBonus < week, "already updated");

        if (assetBalance[assetIndex_] > 0) {
            IERC20(tidalToken).safeTransferFrom(msg.sender, address(this), amount_);
            poolInfo[assetIndex_].bonusPerShare =
                amount_.mul(UNIT_PER_SHARE).div(assetBalance[assetIndex_]);
        }

        poolInfo[assetIndex_].weekOfBonus = week;
    }

    // Called for every user every week.
    function update(address who_) private {
        uint256 week = getWeekByTime(now);

        require(userInfo[who_].week < week, "Already updated");

        uint256 index;
        // Assert if premium or bonus not updated, or user already updated.
        for (index = 0; index < assetManager.getAssetLength(); ++index) {
            require(poolInfo[index].weekOfPremium == week &&
                poolInfo[index].weekOfBonus == week, "Not ready");
        }

        // For every asset
        for (index = 0; index < assetManager.getAssetLength(); ++index) {
            uint256 currentBalance = userBalance[who_][index].currentBalance;
            uint256 futureBalance = userBalance[who_][index].futureBalance;

            // Update premium.
            userInfo[who_].premium = userInfo[who_].premium.add(currentBalance.mul(
                poolInfo[index].premiumPerShare).div(UNIT_PER_SHARE));

            // Update bonus.
            userInfo[who_].bonus = userInfo[who_].bonus.add(currentBalance.mul(
                poolInfo[index].bonusPerShare).div(UNIT_PER_SHARE));

            // Update balances and baskets if no claims.
            if (!isAssetLocked(who_, index)) {
                assetBalance[index] = assetBalance[index].add(futureBalance).sub(currentBalance);
                userBalance[who_][index].currentBalance = futureBalance;
            }
        }

        // Update week.
        userInfo[who_].week = week;
    }

    function isAssetLocked(address who_, uint256 assetIndex_) public view returns(bool) {
        uint256 payoutId = payoutIdMap[assetIndex_];
        return payoutId > 0 && !payoutInfo[payoutId].finished && userPayoutIdMap[who_][assetIndex_] < payoutId;
    }

    function hasPendingPayout(uint256 assetIndex_) public view returns(bool) {
        uint256 payoutId = payoutIdMap[assetIndex_];
        return payoutId > 0 && !payoutInfo[payoutId].finished;
    }

    function deposit(uint256 assetIndex_, uint256 amount_) external {
        require(!hasPendingPayout(assetIndex_), "Has pending payout");
        require(userInfo[msg.sender].week == getWeekByTime(now), "Not updated yet");

        address token = assetManager.getAssetToken(assetIndex_);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount_);

        userBalance[msg.sender][assetIndex_].futureBalance = userBalance[msg.sender][assetIndex_].futureBalance.add(amount_);
    }

    function withdraw(uint256 assetIndex_, uint256 amount_) external {
        require(!hasPendingPayout(assetIndex_), "Has pending payout");

        require(amount_ > 0, "Requires positive amount");
        require(amount_ <= userBalance[msg.sender][assetIndex_].currentBalance, "Not enough user balance");

        WithdrawRequest memory request;
        request.assetIndex = assetIndex_;
        request.amount = amount_;
        request.time = now;
        request.executed = false;
        withdrawRequestMap[msg.sender].push(request);
    }

    function withdrawReady(address who_, uint256 requestIndex_) external {
        WithdrawRequest storage request = withdrawRequestMap[msg.sender][requestIndex_];

        require(!hasPendingPayout(request.assetIndex), "Has pending payout");
        require(userInfo[who_].week == getWeekByTime(now), "Not updated yet");
        require(!request.executed, "already executed");

        uint256 unlockTime = getWithdrawTime(request.time);

        require(now > unlockTime, "Not ready to withdraw yet");

        address token = assetManager.getAssetToken(request.assetIndex);
        IERC20(token).safeTransfer(msg.sender, request.amount);

        assetBalance[request.assetIndex] = assetBalance[request.assetIndex].sub(request.amount);
        userBalance[who_][request.assetIndex].currentBalance = userBalance[who_][request.assetIndex].currentBalance.sub(request.amount);
        userBalance[who_][request.assetIndex].futureBalance = userBalance[who_][request.assetIndex].futureBalance.sub(request.amount);

        request.executed = true;
    }

    function claimPremium() external {
        IERC20(baseToken).safeTransfer(msg.sender, userInfo[msg.sender].premium);
        userInfo[msg.sender].premium = 0;
    }

    function claimBonus() external {
        IERC20(tidalToken).safeTransfer(msg.sender, userInfo[msg.sender].bonus);
        userInfo[msg.sender].bonus = 0;
    }

    function startPayout(uint256 assetIndex_, uint256 payoutId_) external onlyOwner {
        require(payoutId_ == payoutIdMap[assetIndex_] + 1, "payoutId should be increasing");
        payoutIdMap[assetIndex_] = payoutId_;
    }

    function setPayout(uint256 assetIndex_, uint256 payoutId_, address toAddress_, uint256 total_) external onlyOwner {
        require(payoutId_ == payoutIdMap[assetIndex_], "payoutId should be started");
        require(payoutInfo[payoutId_].total == 0, "already set");
        require(total_ <= assetBalance[assetIndex_], "More than asset");

        payoutInfo[payoutId_].toAddress = toAddress_;
        payoutInfo[payoutId_].total = total_;
        payoutInfo[payoutId_].unitPerShare = total_.mul(UNIT_PER_SHARE).div(assetBalance[assetIndex_]);
        payoutInfo[payoutId_].paid = 0;
        payoutInfo[payoutId_].finished = false;
    }

    function doPayout(address who_, uint256 assetIndex_) external {
        for (uint256 payoutId = userPayoutIdMap[who_][assetIndex_] + 1; payoutId <= payoutIdMap[assetIndex_]; ++payoutId) {
            userPayoutIdMap[who_][assetIndex_] = payoutId;

            if (payoutInfo[payoutId].finished) {
                continue;
            }

            uint256 amountToPay = userBalance[who_][assetIndex_].currentBalance.mul(payoutInfo[payoutId].unitPerShare).div(UNIT_PER_SHARE);

            userBalance[who_][assetIndex_].currentBalance = userBalance[who_][assetIndex_].currentBalance.sub(amountToPay);
            userBalance[who_][assetIndex_].futureBalance = userBalance[who_][assetIndex_].futureBalance.sub(amountToPay);
            assetBalance[assetIndex_] = assetBalance[assetIndex_].sub(amountToPay);
            payoutInfo[payoutId].paid = payoutInfo[payoutId].paid.add(amountToPay);
        }
    }

    function finishPayout(uint256 payoutId_) external {
        require(!payoutInfo[payoutId_].finished, "already finished");

        if (payoutInfo[payoutId_].paid < payoutInfo[payoutId_].total) {
            // In case there is still small error.
            IERC20(baseToken).safeTransferFrom(msg.sender, address(this), payoutInfo[payoutId_].total - payoutInfo[payoutId_].paid);
            payoutInfo[payoutId_].paid = payoutInfo[payoutId_].total;
        }

        IERC20(tidalToken).safeTransfer(payoutInfo[payoutId_].toAddress, payoutInfo[payoutId_].total);

        payoutInfo[payoutId_].finished = true;
    }
}
