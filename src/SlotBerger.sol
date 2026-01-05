// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.4;

import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";

struct Slot {
    string content; // provided by user
    uint256 price; // provided by user
    uint256 deposit; // provided by user
    address user; // provided by user
    uint40 timeTaxLastCollected; // automated by contract
    address currency; // provided by DAO
    uint40 timeLastSlotted; // automated by contract
}

/// @notice Slotting with Harberger Tax.
/// @author audsssy.eth
contract SlotBerger {
    /* -------------------------------------------------------------------------- */
    /*                                   Events.                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Emitted when new `Slot` is set.
    event Slotted(
        uint256 indexed id,
        uint256 indexed newPrice,
        string indexed slot
    );

    /* -------------------------------------------------------------------------- */
    /*                                   Error.                                   */
    /* -------------------------------------------------------------------------- */

    error Unauthorized();
    error NotAvailable();
    error InvalidCurrentPrice();
    error InvalidNewPrice();
    error TransferFailed();
    error NothingToCollect();
    error InvalidCurrency();

    /* -------------------------------------------------------------------------- */
    /*                                  Storage.                                  */
    /* -------------------------------------------------------------------------- */

    /// @dev Address authorized to `collect` and `pull`.
    address public dao;

    /// @dev Percentage of ad price to collect as tax, e.g., 100 / 10000
    uint40 public tax;

    /// @dev Bidding cycle in seconds.
    uint40 public cycle;

    /// @dev Minimum increase required to `use()` a slot.
    uint40 public minimum;

    /// @dev Id for slot.
    uint256 public slotId;

    /// @dev Mapping of `Slot` by `slotId`.
    mapping(uint256 id => Slot) slots;

    /// @dev Mapping of currencies accepted by `dao`.
    mapping(address currency => bool) public accepted;

    /* -------------------------------------------------------------------------- */
    /*                          Constructors & Modifier.                          */
    /* -------------------------------------------------------------------------- */

    constructor(address _dao) {
        dao = _dao;

        /// @dev Auto-accept ether as payment method.
        accepted[address(0)] = true;

        /// @dev Hardcoding for demo purposes. You may customize it.
        tax = 100; // 100 / 10000
        cycle = 1 minutes;
        // minimum = 0; // minimum rate of increase per purchase
    }

    /// @dev Modifier to check if `msg.sender` is `dao`.
    modifier authorized() {
        if (msg.sender != dao) revert Unauthorized();
        _;
    }

    /* -------------------------------------------------------------------------- */
    /*                                 Use a Slot.                                */
    /* -------------------------------------------------------------------------- */

    /// @dev Use a slot.
    function use(
        uint256 id,
        string calldata content,
        address currency,
        uint256 currentPrice,
        uint256 newPrice
    ) public payable {
        if (id == 0) {
            // Check approved `currency`.
            if (accepted[currency]) revert InvalidCurrency();

            // Must deposit full tax amount.
            if ((newPrice * tax) / 10000 != msg.value) revert InvalidNewPrice();

            unchecked {
                ++slotId;
            }

            setSlot(slotId, content, currency, newPrice);
        } else {
            Slot memory $ = slots[id];

            // Check bidding cycle.
            if ($.timeLastSlotted + cycle > block.timestamp) {
                revert NotAvailable();
            }

            // Check `currentPrice` and `newPrice` conditions.
            if (currentPrice != $.price) {
                revert InvalidCurrentPrice();
            }
            if (newPrice < currentPrice + (currentPrice * minimum) / 10000) {
                revert InvalidNewPrice();
            }

            // Must deposit full tax amount.
            if ((newPrice * tax) / 10000 != msg.value - currentPrice)
                revert InvalidNewPrice();

            // Check `currency`.
            if ($.currency != currency) revert InvalidCurrency();

            // Calculate collection for buyout.
            uint256 collection = taxToCollect($.price, $.timeTaxLastCollected);

            // Take collection.
            route(currency, address(this), dao, collection);

            // Refund.
            route(currency, address(this), $.user, $.deposit - collection);

            setSlot(id, content, currency, newPrice);
        }
    }

    /// @dev Internal function to set slot.
    function setSlot(
        uint256 id,
        string calldata content,
        address currency,
        uint256 newPrice
    ) internal {
        // Set slot.
        slots[id] = Slot({
            content: content,
            price: newPrice,
            deposit: msg.value,
            user: msg.sender,
            currency: currency,
            timeLastSlotted: uint40(block.timestamp),
            timeTaxLastCollected: uint40(block.timestamp)
        });

        emit Slotted(id, newPrice, content);
    }

    /* -------------------------------------------------------------------------- */
    /*                           Public Functions.                                */
    /* -------------------------------------------------------------------------- */

    /// @dev Retrieve the contents of a slot.
    function getSlot(uint256 id) public view returns (Slot memory) {
        return slots[id];
    }

    /// @dev Public function to calculate amount of tax to collect.
    // credit: simondlr  https://github.com/simondlr/thisartworkisalwaysonsale/blob/master/packages/hardhat/contracts/v1/ArtStewardV2.sol
    function taxToCollect(
        uint256 price,
        uint256 timeTaxLastCollected
    ) public view returns (uint256) {
        return
            ((price * (block.timestamp - timeTaxLastCollected)) * tax) /
            10000 /
            365 days;
    }

    /* -------------------------------------------------------------------------- */
    /*                                    DAO.                                    */
    /* -------------------------------------------------------------------------- */

    /// @dev Collect any tax owed from a slot.
    function collect(
        uint256 id
    ) public payable authorized returns (uint256, uint256) {
        Slot memory $ = slots[id];
        uint256 collection = taxToCollect($.price, $.timeTaxLastCollected);

        if (collection > 0) {
            slots[id].timeTaxLastCollected = uint40(block.timestamp);

            if (collection >= $.deposit) {
                // Foreclose.
                delete slots[id];

                // Take deposit.
                route($.currency, address(this), dao, $.deposit);
                return ($.deposit, 0);
            } else {
                // Take collection.
                route($.currency, address(this), dao, collection);
                return (collection, slots[id].deposit = $.deposit - collection);
            }
        } else {
            return (0, 0);
        }
    }

    /// @dev Pull a given slot by id.
    function pull(uint256 id) public payable authorized {
        Slot memory $ = slots[id];

        // Make collection, if any.
        (, uint256 refund) = collect(id);

        // Delete slot.
        delete slots[id];

        // Refund.
        if (refund > 0) {
            (bool success, ) = $.user.call{value: refund}("");
            if (!success) revert TransferFailed();
        }
    }

    /// @dev Permissioned function to set `dao`.
    function setDao(address _dao) public payable authorized {
        dao = _dao;
    }

    /// @dev Permissioned function to manage slot properties.
    function manageSetting(
        uint40 _tax,
        uint40 _cycle,
        uint40 _minimum
    ) public payable authorized {
        tax = _tax;
        cycle = _cycle;
        minimum = _minimum;
    }

    /// @dev Permissioned function to set an accepted currency.
    function manageCurrency(
        address currency,
        bool status
    ) public payable authorized {
        accepted[currency] = status;
    }

    /* -------------------------------------------------------------------------- */
    /*                                   Helper.                                  */
    /* -------------------------------------------------------------------------- */

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
