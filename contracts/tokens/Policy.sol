// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "../interfaces/IBuyer.sol";
import "../interfaces/IPolicy.sol";


// This token is owned by Timelock.
// Every asset needs have a Policy deployed.
contract Policy is Context, IERC20, IPolicy, Ownable {

    using SafeMath for uint256;

    // who => week => balance
    mapping (address => mapping (uint256 => uint256)) private _balances;

    // owner => spender => week => allowance
    mapping (address => mapping (address => mapping (uint256 => uint256))) private _allowances;

    uint256 private _totalSupply;

    string private _name;
    string private _symbol;

    uint256 public assetIndex;
    uint256 public category;

    // The computing ability of EVM is limited, so we cap the maximum number of weeks
    // in computing at 100. If the gap is larger, just compute multiple times.
    uint256 constant MAXIMUM_WEEK = 100;

    // The base of premium rate and accWeeklyCost
    uint256 constant PREMIUM_BASE = 1e6;

    // Accumulated weekly cost per share.
    mapping(uint256 => uint256) public override accWeeklyCost;

    uint256 public updatedInWeek;

    IBuyer public buyer;

    constructor (
        string memory name_,
        string memory symbol_,
        uint256 assetIndex_,
        uint8 category_,
        IBuyer buyer_
    ) public  {
        _name = name_;
        _symbol = symbol_;
        assetIndex = assetIndex_;
        category = category_;
        buyer = buyer_;
    }

    function getCurrentWeek() public view returns(uint256) {
        return now.div(7 days);
    }

    function isExpired(address who_) public view returns(bool) {
        (uint256 lastWeekCovered,) = buyer.findWeekCovered(who_);
        return lastWeekCovered < getCurrentWeek();
    }

    function getPremiumRate(uint256 week_) public view returns(uint256) {
        if (category == 0) {
            return 14000;
        } else if (category == 1) {
            return 56000;
        } else {
            return 108000;
        }
    }

    function update() public returns(bool) {
        if (updatedInWeek == 0) {
            updatedInWeek = getCurrentWeek();
            return true;
        }

        uint256 count = getCurrentWeek().sub(updatedInWeek);

        bool isUpToDate = true;
        if (count > MAXIMUM_WEEK) {
            count = MAXIMUM_WEEK;
            isUpToDate = false;
        }

        for (uint256 i = 0; i < count; ++i) {
          uint256 weekI = updatedInWeek + i;
          accWeeklyCost[weekI] = accWeeklyCost[weekI].add(getPremiumRate(weekI));
        }

        return isUpToDate;
    }

    function mint() public {
        require(!isExpired(_msgSender()), "not covered this week");

        _mint(_msgSender(), buyer.currentCoveredAmount(msg.sender, assetIndex));
    }

    /**
     * @dev Returns the name of the token.
     */
    function name() public view virtual returns (string memory) {
        return _name;
    }

    /**
     * @dev Returns the symbol of the token, usually a shorter version of the
     * name.
     */
    function symbol() public view virtual returns (string memory) {
        return _symbol;
    }

    /**
     * @dev Returns the number of decimals used to get its user representation.
     * For example, if `decimals` equals `2`, a balance of `505` tokens should
     * be displayed to a user as `5,05` (`505 / 10 ** 2`).
     *
     * Tokens usually opt for a value of 18, imitating the relationship between
     * Ether and Wei. This is the value {ERC20} uses, unless this function is
     * overloaded;
     *
     * NOTE: This information is only used for _display_ purposes: it in
     * no way affects any of the arithmetic of the contract, including
     * {IERC20-balanceOf} and {IERC20-transfer}.
     */
    function decimals() public view virtual returns (uint8) {
        return 18;
    }

    /**
     * @dev See {IERC20-totalSupply}.
     */
    function totalSupply() public view virtual override returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev See {IERC20-balanceOf}.
     */
    function balanceOf(address account) public view virtual override returns (uint256) {
        return _balances[account][getCurrentWeek()];
    }

    /**
     * @dev See {IERC20-transfer}.
     *
     * Requirements:
     *
     * - `recipient` cannot be the zero address.
     * - the caller must have a balance of at least `amount`.
     */
    function transfer(address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(_msgSender(), recipient, amount);
        return true;
    }

    /**
     * @dev See {IERC20-allowance}.
     */
    function allowance(address owner, address spender) public view virtual override returns (uint256) {
        return _allowances[owner][spender][getCurrentWeek()];
    }

    /**
     * @dev See {IERC20-approve}.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function approve(address spender, uint256 amount) public virtual override returns (bool) {
        _approve(_msgSender(), spender, amount);
        return true;
    }

    /**
     * @dev See {IERC20-transferFrom}.
     *
     * Emits an {Approval} event indicating the updated allowance. This is not
     * required by the EIP. See the note at the beginning of {ERC20}.
     *
     * Requirements:
     *
     * - `sender` and `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     * - the caller must have allowance for ``sender``'s tokens of at least
     * `amount`.
     */
    function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool) {
        _transfer(sender, recipient, amount);

        uint256 currentAllowance = _allowances[sender][_msgSender()][getCurrentWeek()];
        require(currentAllowance >= amount, "ERC20: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);

        return true;
    }

    /**
     * @dev Atomically increases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     */
    function increaseAllowance(address spender, uint256 addedValue) public virtual returns (bool) {
        _approve(_msgSender(), spender, _allowances[_msgSender()][spender][getCurrentWeek()] + addedValue);
        return true;
    }

    /**
     * @dev Atomically decreases the allowance granted to `spender` by the caller.
     *
     * This is an alternative to {approve} that can be used as a mitigation for
     * problems described in {IERC20-approve}.
     *
     * Emits an {Approval} event indicating the updated allowance.
     *
     * Requirements:
     *
     * - `spender` cannot be the zero address.
     * - `spender` must have allowance for the caller of at least
     * `subtractedValue`.
     */
    function decreaseAllowance(address spender, uint256 subtractedValue) public virtual returns (bool) {
        uint256 currentAllowance = _allowances[_msgSender()][spender][getCurrentWeek()];
        require(currentAllowance >= subtractedValue, "ERC20: decreased allowance below zero");
        _approve(_msgSender(), spender, currentAllowance - subtractedValue);

        return true;
    }

    /**
     * @dev Moves tokens `amount` from `sender` to `recipient`.
     *
     * This is internal function is equivalent to {transfer}, and can be used to
     * e.g. implement automatic token fees, slashing mechanisms, etc.
     *
     * Emits a {Transfer} event.
     *
     * Requirements:
     *
     * - `sender` cannot be the zero address.
     * - `recipient` cannot be the zero address.
     * - `sender` must have a balance of at least `amount`.
     */
    function _transfer(address sender, address recipient, uint256 amount) internal virtual {
        require(sender != address(0), "ERC20: transfer from the zero address");
        require(recipient != address(0), "ERC20: transfer to the zero address");

        uint256 currentWeek = getCurrentWeek();

        uint256 senderBalance = _balances[sender][currentWeek];
        require(senderBalance >= amount, "ERC20: transfer amount exceeds balance");
        _balances[sender][currentWeek] = senderBalance - amount;
        _balances[recipient][currentWeek] += amount;

        emit Transfer(sender, recipient, amount);
    }

    /** @dev Creates `amount` tokens and assigns them to `account`, increasing
     * the total supply.
     *
     * Emits a {Transfer} event with `from` set to the zero address.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     */
    function _mint(address account, uint256 amount) internal virtual {
        require(account != address(0), "ERC20: mint to the zero address");

        _totalSupply += amount;
        _balances[account][getCurrentWeek()] += amount;
        emit Transfer(address(0), account, amount);
    }

    /**
     * @dev Sets `amount` as the allowance of `spender` over the `owner` s tokens.
     *
     * This internal function is equivalent to `approve`, and can be used to
     * e.g. set automatic allowances for certain subsystems, etc.
     *
     * Emits an {Approval} event.
     *
     * Requirements:
     *
     * - `owner` cannot be the zero address.
     * - `spender` cannot be the zero address.
     */
    function _approve(address owner, address spender, uint256 amount) internal virtual {
        require(owner != address(0), "ERC20: approve from the zero address");
        require(spender != address(0), "ERC20: approve to the zero address");

        _allowances[owner][spender][getCurrentWeek()] = amount;
        emit Approval(owner, spender, amount);
    }
}
