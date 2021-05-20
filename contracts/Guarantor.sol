// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./NonReentrancy.sol";
import "./WeekManaged.sol";

import "./interfaces/IAssetManager.sol";
import "./interfaces/IBuyer.sol";
import "./interfaces/IGuarantor.sol";
import "./interfaces/IRegistry.sol";


// This contract is owned by Timelock.
contract Guarantor is IGuarantor, Ownable, WeekManaged, NonReentrancy {

    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    IRegistry public registry;

    struct WithdrawRequest {
        uint256 amount;
        uint256 time;
        bool executed;
    }

    // who => week => assetIndex => WithdrawRequest
    mapping(address => mapping(uint256 => mapping(uint16 => WithdrawRequest))) public withdrawRequestMap;

    struct PoolInfo {
        uint256 weekOfPremium;
        uint256 weekOfBonus;
        uint256 premiumPerShare;
        uint256 bonusPerShare;
    }

    mapping(uint16 => PoolInfo) public poolInfo;

    struct UserBalance {
        uint256 currentBalance;
        uint256 futureBalance;
    }

    mapping(address => mapping(uint16 => UserBalance)) public userBalance;

    struct UserInfo {
        uint256 week;
        uint256 premium;
        uint256 bonus;
    }

    mapping(address => UserInfo) public userInfo;

    // Balance here not withdrawn yet, and are good for staking bonus.
    // assetIndex => amount
    mapping(uint16 => uint256) public assetBalance;

    struct PayoutInfo {
        address toAddress;
        uint256 total;
        uint256 unitPerShare;
        uint256 paid;
        bool finished;
    }

    // assetIndex => payoutId => PayoutInfo
    mapping(uint16 => mapping(uint256 => PayoutInfo)) public payoutInfo;

    // assetIndex => payoutId
    mapping(uint16 => uint256) public payoutIdMap;

    // who => assetIndex => payoutId
    mapping(address => mapping(uint16 => uint256)) userPayoutIdMap;

    constructor () public { }

    function setRegistry(IRegistry registry_) external onlyOwner {
        registry = registry_;
    }

    // Update and pay last week's premium.
    function updatePremium(uint16 assetIndex_) external lock {
        uint256 week = getCurrentWeek();
        require(IBuyer(registry.buyer()).weekToUpdate() == week, "buyer not ready");
        require(poolInfo[assetIndex_].weekOfPremium < week, "already updated");

        uint256 amount = IBuyer(registry.buyer()).premiumForGuarantor(assetIndex_);

        if (assetBalance[assetIndex_] > 0) {
            IERC20(registry.baseToken()).safeTransferFrom(registry.buyer(), address(this), amount);
            poolInfo[assetIndex_].premiumPerShare =
                amount.mul(registry.UNIT_PER_SHARE()).div(assetBalance[assetIndex_]);
        }

        poolInfo[assetIndex_].weekOfPremium = week;
    }

    // Update and pay last week's bonus.
    function updateBonus(uint16 assetIndex_, uint256 amount_) external lock override {
        require(msg.sender == registry.bonus(), "Only Bonus can call");

        uint256 week = getCurrentWeek();

        require(poolInfo[assetIndex_].weekOfBonus < week, "already updated");

        if (assetBalance[assetIndex_] > 0) {
            IERC20(registry.tidalToken()).safeTransferFrom(msg.sender, address(this), amount_);
            poolInfo[assetIndex_].bonusPerShare =
                amount_.mul(registry.UNIT_PER_SHARE()).div(assetBalance[assetIndex_]);
        }

        poolInfo[assetIndex_].weekOfBonus = week;
    }

    // Called for every user every week.
    function update(address who_) external {
        uint256 week = getCurrentWeek();

        require(userInfo[who_].week < week, "Already updated");

        uint16 index;
        // Assert if premium or bonus not updated, or user already updated.
        for (index = 0; index < IAssetManager(registry.assetManager()).getAssetLength(); ++index) {
            require(poolInfo[index].weekOfPremium == week &&
                poolInfo[index].weekOfBonus == week, "Not ready");
        }

        // For every asset
        for (index = 0; index < IAssetManager(registry.assetManager()).getAssetLength(); ++index) {
            uint256 currentBalance = userBalance[who_][index].currentBalance;
            uint256 futureBalance = userBalance[who_][index].futureBalance;

            // Update premium.
            userInfo[who_].premium = userInfo[who_].premium.add(currentBalance.mul(
                poolInfo[index].premiumPerShare).div(registry.UNIT_PER_SHARE()));

            // Update bonus.
            userInfo[who_].bonus = userInfo[who_].bonus.add(currentBalance.mul(
                poolInfo[index].bonusPerShare).div(registry.UNIT_PER_SHARE()));

            // Update balances and baskets if no claims.
            if (!isAssetLocked(who_, index)) {
                assetBalance[index] = assetBalance[index].add(futureBalance).sub(currentBalance);
                userBalance[who_][index].currentBalance = futureBalance;
            }
        }

        // Update week.
        userInfo[who_].week = week;
    }

    function isAssetLocked(address who_, uint16 assetIndex_) public view returns(bool) {
        uint256 payoutId = payoutIdMap[assetIndex_];
        return payoutId > 0 && !payoutInfo[assetIndex_][payoutId].finished && userPayoutIdMap[who_][assetIndex_] < payoutId;
    }

    function hasPendingPayout(uint16 assetIndex_) public view returns(bool) {
        uint256 payoutId = payoutIdMap[assetIndex_];
        return payoutId > 0 && !payoutInfo[assetIndex_][payoutId].finished;
    }

    function deposit(uint16 assetIndex_, uint256 amount_) external lock {
        require(!hasPendingPayout(assetIndex_), "Has pending payout");
        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");

        address token = IAssetManager(registry.assetManager()).getAssetToken(assetIndex_);
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount_);

        userBalance[msg.sender][assetIndex_].futureBalance = userBalance[msg.sender][assetIndex_].futureBalance.add(amount_);
    }

    function reduceDeposit(uint16 assetIndex_, uint256 amount_) external lock {
        // Even asset locked, user can still reduce.

        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");
        require(amount_ <= userBalance[msg.sender][assetIndex_].futureBalance.sub(
            userBalance[msg.sender][assetIndex_].currentBalance), "Not enough future balance");

        address token = IAssetManager(registry.assetManager()).getAssetToken(assetIndex_);
        IERC20(token).safeTransfer(msg.sender, amount_);

        userBalance[msg.sender][assetIndex_].futureBalance = userBalance[msg.sender][assetIndex_].futureBalance.sub(amount_);
    }

    function withdraw(uint16 assetIndex_, uint256 amount_) external {
        require(!hasPendingPayout(assetIndex_), "Has pending payout");

        require(userInfo[msg.sender].week == getCurrentWeek(), "Not updated yet");

        require(amount_ > 0, "Requires positive amount");
        require(amount_ <= userBalance[msg.sender][assetIndex_].currentBalance, "Not enough user balance");

        WithdrawRequest memory request;
        request.amount = amount_;
        request.time = getNow();
        request.executed = false;
        withdrawRequestMap[msg.sender][getUnlockWeek()][assetIndex_] = request;
    }

    function withdrawReady(address who_, uint16 assetIndex_) external lock {
        WithdrawRequest storage request = withdrawRequestMap[who_][getCurrentWeek()][assetIndex_];

        require(!hasPendingPayout(assetIndex_), "Has pending payout");
        require(userInfo[who_].week == getCurrentWeek(), "Not updated yet");
        require(!request.executed, "already executed");
        require(request.time > 0, "No request");

        uint256 unlockTime = getUnlockTime(request.time);
        require(getNow() > unlockTime, "Not ready to withdraw yet");

        address token = IAssetManager(registry.assetManager()).getAssetToken(assetIndex_);
        IERC20(token).safeTransfer(who_, request.amount);

        assetBalance[assetIndex_] = assetBalance[assetIndex_].sub(request.amount);
        userBalance[who_][assetIndex_].currentBalance = userBalance[who_][assetIndex_].currentBalance.sub(request.amount);
        userBalance[who_][assetIndex_].futureBalance = userBalance[who_][assetIndex_].futureBalance.sub(request.amount);

        request.executed = true;
    }

    function claimPremium() external lock {
        IERC20(registry.baseToken()).safeTransfer(msg.sender, userInfo[msg.sender].premium);
        userInfo[msg.sender].premium = 0;
    }

    function claimBonus() external lock {
        IERC20(registry.tidalToken()).safeTransfer(msg.sender, userInfo[msg.sender].bonus);
        userInfo[msg.sender].bonus = 0;
    }

    function startPayout(uint16 assetIndex_, uint256 payoutId_) external override {
        require(msg.sender == registry.committee(), "Only commitee can call");

        require(payoutId_ == payoutIdMap[assetIndex_] + 1, "payoutId should be increasing");
        payoutIdMap[assetIndex_] = payoutId_;
    }

    function setPayout(uint16 assetIndex_, uint256 payoutId_, address toAddress_, uint256 total_) external override {
        require(msg.sender == registry.committee(), "Only commitee can call");

        require(payoutId_ == payoutIdMap[assetIndex_], "payoutId should be started");
        require(payoutInfo[assetIndex_][payoutId_].toAddress == address(0), "already set");
        require(total_ <= assetBalance[assetIndex_], "More than asset");

        // total_ can be 0.

        payoutInfo[assetIndex_][payoutId_].toAddress = toAddress_;
        payoutInfo[assetIndex_][payoutId_].total = total_;
        payoutInfo[assetIndex_][payoutId_].unitPerShare = total_.mul(registry.UNIT_PER_SHARE()).div(assetBalance[assetIndex_]);
        payoutInfo[assetIndex_][payoutId_].paid = 0;
        payoutInfo[assetIndex_][payoutId_].finished = false;
    }

    // This function can be called by anyone.
    function doPayout(address who_, uint16 assetIndex_) external {
        uint256 payoutId = payoutIdMap[assetIndex_];
        
        require(payoutInfo[assetIndex_][payoutId].toAddress != address(0), "not set");
        require(userPayoutIdMap[who_][assetIndex_] < payoutId, "Already paid");

        userPayoutIdMap[who_][assetIndex_] = payoutId;

        if (payoutInfo[assetIndex_][payoutId].finished) {
            // In case someone paid for the difference.
            return;
        }

        uint256 amountToPay = userBalance[who_][assetIndex_].currentBalance.mul(
            payoutInfo[assetIndex_][payoutId].unitPerShare).div(registry.UNIT_PER_SHARE());

        userBalance[who_][assetIndex_].currentBalance = userBalance[who_][assetIndex_].currentBalance.sub(amountToPay);
        userBalance[who_][assetIndex_].futureBalance = userBalance[who_][assetIndex_].futureBalance.sub(amountToPay);
        assetBalance[assetIndex_] = assetBalance[assetIndex_].sub(amountToPay);
        payoutInfo[assetIndex_][payoutId].paid = payoutInfo[assetIndex_][payoutId].paid.add(amountToPay);
    }

    // This function can be called by anyone as long as he will pay for the difference.
    function finishPayout(uint16 assetIndex_, uint256 payoutId_) external lock {
        require(payoutId_ <= payoutIdMap[assetIndex_], "payoutId should be valid");
        require(!payoutInfo[assetIndex_][payoutId_].finished, "already finished");

        address token = IAssetManager(registry.assetManager()).getAssetToken(assetIndex_);

        if (payoutInfo[assetIndex_][payoutId_].paid < payoutInfo[assetIndex_][payoutId_].total) {
            // In case there is still small error.
            IERC20(token).safeTransferFrom(
                msg.sender,
                address(this),
                payoutInfo[assetIndex_][payoutId_].total.sub(payoutInfo[assetIndex_][payoutId_].paid));
            payoutInfo[assetIndex_][payoutId_].paid = payoutInfo[assetIndex_][payoutId_].total;
        }

        IERC20(token).safeTransfer(payoutInfo[assetIndex_][payoutId_].toAddress,
                           payoutInfo[assetIndex_][payoutId_].total);

        payoutInfo[assetIndex_][payoutId_].finished = true;
    }
}
