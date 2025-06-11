// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface mở rộng của WETH
interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

contract DexContract {
    IERC20 public token;       // ERC20 token (không phải WETH)
    IWETH public WETH;         // WETH contract

    uint256 public reserveToken;
    uint256 public reserveWETH;

    uint256 public totalLiquidity;
    mapping(address => uint256) public liquidity;

    uint256 public constant FEE_PERCENT = 5;
    uint256 public constant FEE_DENOMINATOR = 1000;

    event LiquidityAdded(address indexed provider, uint256 amountToken, uint256 amountETH, uint256 liquidityMinted);
    event LiquidityRemoved(address indexed provider, uint256 amountToken, uint256 amountETH, uint256 liquidityBurned);
    event Swap(address indexed swapper, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);

    constructor(address _token, address _weth) {
        token = IERC20(_token);
        WETH = IWETH(_weth);
    }

    function _updateReserves() internal {
        reserveToken = token.balanceOf(address(this));
        reserveWETH = WETH.balanceOf(address(this));
    }

    function addLiquidityETH(uint256 amountToken, uint256 minLiquidity) external payable returns (uint256 liquidityMinted) {
        require(amountToken > 0 && msg.value > 0, "Invalid amounts");

        require(token.transferFrom(msg.sender, address(this), amountToken), "Token transfer failed");

        WETH.deposit{value: msg.value}();

        if (totalLiquidity == 0) {
            liquidityMinted = sqrt(amountToken * msg.value);
        } else {
            liquidityMinted = min(
                (amountToken * totalLiquidity) / reserveToken,
                (msg.value * totalLiquidity) / reserveWETH
            );
        }

        require(liquidityMinted >= minLiquidity, "Insufficient liquidity minted");

        liquidity[msg.sender] += liquidityMinted;
        totalLiquidity += liquidityMinted;

        _updateReserves();

        emit LiquidityAdded(msg.sender, amountToken, msg.value, liquidityMinted);
    }

    function removeLiquidity(uint256 liquidityAmount) external returns (uint256 amountToken, uint256 amountETH) {
        require(liquidityAmount > 0 && liquidity[msg.sender] >= liquidityAmount, "Invalid liquidity");

        amountToken = (liquidityAmount * reserveToken) / totalLiquidity;
        uint256 amountWETH = (liquidityAmount * reserveWETH) / totalLiquidity;

        liquidity[msg.sender] -= liquidityAmount;
        totalLiquidity -= liquidityAmount;

        require(token.transfer(msg.sender, amountToken), "Token transfer failed");
        WETH.withdraw(amountWETH);
        (bool sent, ) = msg.sender.call{value: amountWETH}("");
        require(sent, "ETH transfer failed");

        _updateReserves();

        emit LiquidityRemoved(msg.sender, amountToken, amountWETH, liquidityAmount);
    }

    function swapExactETHForToken(uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        require(msg.value > 0, "No ETH sent");

        WETH.deposit{value: msg.value}();

        uint256 amountInWithFee = msg.value * (FEE_DENOMINATOR - FEE_PERCENT) / FEE_DENOMINATOR;
        tokensOut = (amountInWithFee * reserveToken) / (reserveWETH + amountInWithFee);
        require(tokensOut >= minTokensOut, "Insufficient output");

        require(token.transfer(msg.sender, tokensOut), "Token transfer failed");

        _updateReserves();

        emit Swap(msg.sender, address(WETH), msg.value, address(token), tokensOut);
    }

    function swapExactTokenForETH(uint256 amountIn, uint256 minETHOut) external returns (uint256 ethOut) {
        require(amountIn > 0, "No token sent");

        require(token.transferFrom(msg.sender, address(this), amountIn), "Token transfer failed");

        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_PERCENT) / FEE_DENOMINATOR;
        ethOut = (amountInWithFee * reserveWETH) / (reserveToken + amountInWithFee);
        require(ethOut >= minETHOut, "Insufficient output");

        WETH.withdraw(ethOut);
        (bool sent, ) = msg.sender.call{value: ethOut}("");
        require(sent, "ETH transfer failed");

        _updateReserves();

        emit Swap(msg.sender, address(token), amountIn, address(WETH), ethOut);
    }

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function min(uint x, uint y) internal pure returns (uint) {
        return x < y ? x : y;
    }

    receive() external payable {}
    fallback() external payable {}
}
