// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.4;

interface IERC20 {
    function transferFrom(
        address from,
        address to,
        uint256 amount
    ) external returns (bool);
}

// import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

struct Slot {
    string content; // provided by user
    uint256 price; // provided by user
    address owner; // provided by user
    bool paused; // provided by user
    bool pending;
    address currency; // provided by user
    uint8 tax; // provided by user
    uint40 term; // provided by user
    uint40 remainingTime;
    address user; // automated by contract
    uint40 lastTimestamp;
    uint256 deposit;
}

struct Bid {
    uint256 price; // provided by user
    uint256 deposit;
    address currency; // provided by user
    address user; // automated by contract
    uint40 remainingTime;
    uint40 lastTimestamp;
}

/// @notice Slotting with Harberger Tax.
/// @notice Monetize global, manufacture local
/// @author audsssy.eth
contract SlotBerger {
    /* -------------------------------------------------------------------------- */
    /*                                   Events.                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Emitted when new `Slot` is set.
    event Slotted(uint256 indexed id, uint256 indexed tax, string indexed slot);

    /* -------------------------------------------------------------------------- */
    /*                                   Error.                                   */
    /* -------------------------------------------------------------------------- */

    error Paused();
    error Unauthorized();
    error NotAvailable();
    error InvalidPrice();
    error TransferFailed();
    error NoBidsToProcess();
    error InvalidCurrency();

    /* -------------------------------------------------------------------------- */
    /*                                  Storage.                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Address authorized to manage `acceptedCurrencies`.
    address public dao;

    /// @dev Id for slot.
    uint256 public slotId;

    /// @dev Mapping of `Slot` by `slotId`.
    mapping(uint256 => Slot) slots;

    /// @dev Mapping of highest `Bid` by `slotId`.
    mapping(uint256 => Bid) bids;

    /// @dev Mapping of permitted currencies.
    mapping(address => bool) public acceptedCurrencies;

    /* -------------------------------------------------------------------------- */
    /*                          Constructors & Modifier.                          */
    /* -------------------------------------------------------------------------- */

    constructor(address _dao) {
        dao = _dao;
        acceptedCurrencies[address(0)] = true;
    }

    modifier onlyDao() {
        if (msg.sender != dao) revert Unauthorized();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Use a Slot.                                */
    /* -------------------------------------------------------------------------- */

    /// @dev Set up a slot.
    function setup(
        uint256 id,
        string calldata content,
        address currency,
        uint8 tax,
        uint40 term
    ) public payable {
        if (id == 0) {
            // Setup a new slot.
            if (!acceptedCurrencies[currency]) revert InvalidCurrency();
            unchecked {
                setSlot(++slotId, content, currency, tax, term);
            }
        } else {
            // Update a slot.
            Slot memory $ = slots[id];
            if ($.owner != msg.sender) revert Unauthorized();
            if ($.user != address(0)) revert NotAvailable();
            updateSlot(id, currency, tax, term);
        }
    }

    /// @dev Acquire rights to a slotted content.
    function acquire(
        uint256 id,
        address currency,
        uint256 price
    ) public payable {
        // Check if in use.
        Slot storage $ = slots[id];
        if ($.user != address(0)) revert NotAvailable();

        // Check `currency`.
        if (!acceptedCurrencies[currency]) revert InvalidCurrency();

        // Route price.
        route(currency, msg.sender, $.owner, price);

        // Deposit patronage.
        uint256 patronage = (price * $.tax) / 10000;
        route(currency, msg.sender, address(this), patronage);

        // Set data.
        $.remainingTime = $.term;
        $.lastTimestamp = uint40(block.timestamp);
        $.deposit = patronage;
        $.user = msg.sender;
    }

    /// @dev Bid on rights to a slotted content.
    function bid(uint256 id, address currency, uint256 price) public {
        Slot storage $ = slots[id];
        if ($.price + ($.price * $.tax) / 10000 >= price) revert InvalidPrice();

        Bid storage $bid = bids[id];
        if ($bid.price > price) revert InvalidPrice();

        // Deposit bid.
        route(currency, msg.sender, address(this), price);

        // Set bid.
        $bid.price = price;
        $bid.currency = currency;
        $bid.user = msg.sender;
    }

    function processBid(uint256 id) public {
        Slot storage $ = slots[id];
        if ($.lastTimestamp + $.remainingTime > block.timestamp)
            revert NotAvailable();

        Bid storage $bid = bids[id];
        if ($bid.user == address(0)) revert NotAvailable();
        uint256 deposit = ($bid.price * $.tax) / 10000;
        route($bid.currency, address(this), $.owner, $bid.price - deposit);

        $.user = $bid.user;
        $.deposit = deposit;
        $.currency = $bid.currency;
        $.lastTimestamp = uint40(block.timestamp);
        $.remainingTime = $.term;
    }

    /// @dev Internal function to set slot.
    function setSlot(
        uint256 id,
        string memory content,
        address currency,
        uint8 tax,
        uint40 term
    ) internal {
        Slot storage $ = slots[id];
        $.content = content;
        $.owner = msg.sender;
        $.currency = currency;
        $.tax = tax;
        $.term = term;

        emit Slotted(id, tax, content);
    }

    /// @dev Internal function to set slot.
    function updateSlot(
        uint256 id,
        address currency,
        uint8 tax,
        uint40 term
    ) internal {
        Slot storage $ = slots[id];
        $.owner = msg.sender;
        $.currency = currency;
        $.tax = tax;
        $.term = term;

        emit Slotted(id, tax, "");
    }
    /* -------------------------------------------------------------------------- */
    /*                                 Get a Slot.                                */
    /* -------------------------------------------------------------------------- */

    /// @dev Retrieve the contents of a slot.
    function getSlot(uint256 id) public view returns (Slot memory) {
        return slots[id];
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Owner.                                   */
    /* -------------------------------------------------------------------------- */

    /// @dev Pull a given `Slot`.
    function pull(uint256 id) public payable {
        Slot storage $ = slots[id];
        if (msg.sender != $.owner) revert Unauthorized();
        if ($.lastTimestamp + $.remainingTime > block.timestamp)
            revert NotAvailable();

        // todo. check if works with pause()
        uint256 timePassed = uint40(block.timestamp) - $.lastTimestamp;
        uint256 patronage = patronageOwed($.price, $.tax, timePassed, $.term);
        route($.currency, address(this), address(this), patronage);

        // Delete slot.
        delete slots[id];
    }

    /// @dev Pause/unpause a given `Slot`.
    function pause(uint256 id) public payable {
        Slot storage $ = slots[id];
        if (msg.sender != $.owner) revert Unauthorized();
        if ($.user == address(0)) revert NotAvailable();

        if (!$.paused) {
            uint256 timePassed = uint40(block.timestamp) - $.lastTimestamp;
            uint256 patronage = patronageOwed(
                $.price,
                $.tax,
                timePassed,
                $.term
            );
            route($.currency, address(this), address(this), patronage);
            $.deposit -= patronage;
        }
        if ($.paused) $.lastTimestamp = uint40(block.timestamp);
        $.paused = !$.paused;
    }

    /* -------------------------------------------------------------------------- */
    /*                                    DAO.                                    */
    /* -------------------------------------------------------------------------- */

    function setDao(address _dao) public payable onlyDao {
        dao = _dao;
    }

    function manageCurrency(
        address currency,
        bool status
    ) public payable onlyDao {
        acceptedCurrencies[currency] = status;
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Helper.                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Helper function to calculate patronage owed.
    // credit: simondlr  https://github.com/simondlr/thisartworkisalwaysonsale/blob/master/packages/hardhat/contracts/v1/ArtStewardV2.sol
    function patronageOwed(
        uint256 price,
        uint256 tax,
        uint256 timePassed,
        uint256 term
    ) private pure returns (uint256 patronage) {
        uint256 totalPatronage = (price * tax) / 10000;
        uint256 usageInPercentage = (timePassed * 100) / term / 100;
        return totalPatronage * usageInPercentage;
    }

    /// @dev Helper function to route ether and ERC20 tokens.
    function route(
        address currency,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (currency == address(0)) {
            (bool success, ) = to.call{value: amount}("");
            if (!success) revert TransferFailed();
        } else {
            IERC20(currency).transferFrom(from, to, amount);
        }
    }

    receive() external payable virtual {}
}
