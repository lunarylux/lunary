// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title Lunary Token (LUX)
 * @notice Immutable ERC-20. Only the mining contract can mint.
 *         Decimals 8, max supply 112,333.
 */
contract LunaryToken is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    uint8 private constant _DECIMALS = 8;
    uint256 public constant MAX_SUPPLY = 112_333 * 10**_DECIMALS;

    /// @notice Mining contract allowed to mint LUX
    address public miningContract;
    /// @notice True after mining contract has been set (one-time lock)
    bool public miningContractLocked;

    event MiningContractSet(address indexed miningContract);
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    constructor() ERC20("Lunary", "LUX") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return _DECIMALS;
    }

    // ============ MINING CONTRACT ============
    /**
     * @notice Set mining contract address. Can only be called ONCE.
     * @dev After this call, only the mining contract can mint LUX.
     */
    function setMiningContract(address _mining) external onlyOwner {
        require(!miningContractLocked, "Already locked");
        require(_mining != address(0), "Zero address");
        miningContract = _mining;
        miningContractLocked = true;
        emit MiningContractSet(_mining);
    }

    // ============ MINT ============
    /**
     * @notice Mint LUX. Only callable by the mining contract.
     */
    function mint(address to, uint256 amount) external {
        require(msg.sender == miningContract, "Only mining contract");
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply exceeded");
        _mint(to, amount);
    }

    // ============ RECEIVE ============
    /// @notice Accept ETH transfers (e.g. accidental sends)
    receive() external payable {}

    // ============ RESCUE ============
    /**
     * @notice Rescue ETH accidentally sent to this contract.
     * @dev Sends to owner. Uses ReentrancyGuard for safety.
     */
    function rescueETH() external onlyOwner nonReentrant {
        uint256 balance = address(this).balance;
        require(balance > 0, "No ETH to rescue");

        address to = owner();
        (bool ok, ) = to.call{value: balance}("");
        require(ok, "ETH transfer failed");

        emit ETHRescued(to, balance);
    }

    /**
     * @notice Rescue any ERC-20 token accidentally sent to this contract.
     * @param _token Token address to rescue
     * @param amount Amount to rescue
     * @dev Cannot rescue LUX itself via this function — LUX is minted by mining
     *      and never held here by design. If LUX somehow ends up here, use
     *      rescueLUX() (added below).
     */
    function rescueERC20(address _token, uint256 amount) external onlyOwner nonReentrant {
        require(_token != address(this), "Use rescueLUX for LUX");
        require(_token != address(0), "Zero token address");
        require(amount > 0, "Amount is zero");

        address to = owner();
        IERC20(_token).safeTransfer(to, amount);

        emit ERC20Rescued(_token, to, amount);
    }

    /**
     * @notice Rescue LUX accidentally sent to this contract.
     * @dev Separate function because LUX is this contract's own token.
     */
    function rescueLUX(uint256 amount) external onlyOwner nonReentrant {
        require(amount > 0, "Amount is zero");
        require(amount <= balanceOf(address(this)), "Insufficient LUX balance");

        address to = owner();
        _transfer(address(this), to, amount);

        emit ERC20Rescued(address(this), to, amount);
    }

    // ============ VIEWS ============
    function getETHBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function getERC20Balance(address _token) external view returns (uint256) {
        return IERC20(_token).balanceOf(address(this));
    }

    function getLUXBalance() external view returns (uint256) {
        return balanceOf(address(this));
    }
}