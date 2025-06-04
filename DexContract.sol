// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// Interface WETH mở rộng từ IERC20, có thêm deposit và withdraw để wrap/unwrap ETH
interface IWETH is IERC20 {
    function deposit() external payable; // wrap ETH -> WETH
    function withdraw(uint) external;   // unwrap WETH -> ETH
}

contract SimpleDex {
    IERC20 public tokenA;    // Token A trong cặp
    IERC20 public tokenB;    // Token B trong cặp, có thể là WETH
    IWETH public WETH;       // Contract WETH để wrap/unwrap ETH

    uint256 public reserveA; // Dự trữ tokenA trong pool
    uint256 public reserveB; // Dự trữ tokenB trong pool

    uint256 public totalLiquidity;               // Tổng lượng liquidity token mint ra
    mapping(address => uint256) public liquidity; // Lượng liquidity mỗi provider giữ

    // Fee: 0.5% (5 / 1000)
    uint256 public constant FEE_PERCENT = 5;  
    uint256 public constant FEE_DENOMINATOR = 1000;

    // Sự kiện khi thêm liquidity
    event LiquidityAdded(address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidityMinted);
    // Sự kiện khi rút liquidity
    event LiquidityRemoved(address indexed provider, uint256 amountA, uint256 amountB, uint256 liquidityBurned);
    // Sự kiện swap token
    event Swap(address indexed swapper, address tokenIn, uint256 amountIn, address tokenOut, uint256 amountOut);

    // Hàm khởi tạo contract, truyền địa chỉ token A, token B và WETH
    constructor(address _tokenA, address _tokenB, address _weth) {
        tokenA = IERC20(_tokenA);
        tokenB = IERC20(_tokenB);
        WETH = IWETH(_weth);
    }

    // Cập nhật lại dự trữ của token A và B trong contract
    function _updateReserves() internal {
        reserveA = tokenA.balanceOf(address(this));
        reserveB = tokenB.balanceOf(address(this));
    }

    // Hàm add liquidity vào pool
    function addLiquidity(uint256 amountA, uint256 amountB) external returns (uint256 liquidityMinted) {
        require(amountA > 0 && amountB > 0, "Amounts must be > 0");

        // Người dùng chuyển tokenA và tokenB cho contract
        require(tokenA.transferFrom(msg.sender, address(this), amountA), "Transfer A failed");
        require(tokenB.transferFrom(msg.sender, address(this), amountB), "Transfer B failed");

        if (totalLiquidity == 0) {
            // Lần đầu tiên add liquidity thì mint liquidity bằng căn bậc 2 của tích lượng token
            liquidityMinted = sqrt(amountA * amountB);
            require(liquidityMinted > 0, "Insufficient liquidity minted");
            totalLiquidity = liquidityMinted;
            liquidity[msg.sender] = liquidityMinted;
        } else {
            // Lần tiếp theo mint dựa trên tỉ lệ dự trữ hiện tại
            liquidityMinted = min(
                (amountA * totalLiquidity) / reserveA,
                (amountB * totalLiquidity) / reserveB
            );
            require(liquidityMinted > 0, "Insufficient liquidity minted");
            liquidity[msg.sender] += liquidityMinted;
            totalLiquidity += liquidityMinted;
        }

        _updateReserves();

        emit LiquidityAdded(msg.sender, amountA, amountB, liquidityMinted);
    }

    // Rút liquidity, trả tokenA và tokenB tương ứng cho người dùng
    function removeLiquidity(uint256 liquidityAmount) external returns (uint256 amountA, uint256 amountB) {
        require(liquidityAmount > 0, "Liquidity must be > 0");
        require(liquidity[msg.sender] >= liquidityAmount, "Not enough liquidity");

        // Tính lượng token trả về theo tỉ lệ liquidity
        amountA = (liquidityAmount * reserveA) / totalLiquidity;
        amountB = (liquidityAmount * reserveB) / totalLiquidity;

        liquidity[msg.sender] -= liquidityAmount;
        totalLiquidity -= liquidityAmount;

        require(tokenA.transfer(msg.sender, amountA), "Transfer A failed");
        require(tokenB.transfer(msg.sender, amountB), "Transfer B failed");

        _updateReserves();

        emit LiquidityRemoved(msg.sender, amountA, amountB, liquidityAmount);
    }

    // Swap ETH sang token (token không phải ETH)
    function swapExactETHForToken(uint256 minTokensOut) external payable returns (uint256 tokensOut) {
        require(address(tokenA) == address(WETH) || address(tokenB) == address(WETH), "WETH not in pair");
        require(msg.value > 0, "Must send ETH");

        // Wrap ETH thành WETH
        WETH.deposit{value: msg.value}();

        bool wethIsTokenA = address(tokenA) == address(WETH);

        uint256 reserveIn = wethIsTokenA ? reserveA : reserveB;
        uint256 reserveOut = wethIsTokenA ? reserveB : reserveA;

        // Tính amountIn với fee
        uint256 amountInWithFee = msg.value * (FEE_DENOMINATOR - FEE_PERCENT) / FEE_DENOMINATOR;

        // Công thức AMM: x * y = k
        tokensOut = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
        require(tokensOut >= minTokensOut, "Insufficient output");

        // Transfer token ra cho người swap
        if (wethIsTokenA) {
            require(tokenB.transfer(msg.sender, tokensOut), "Transfer tokenB failed");
        } else {
            require(tokenA.transfer(msg.sender, tokensOut), "Transfer tokenA failed");
        }

        _updateReserves();

        emit Swap(msg.sender, address(WETH), msg.value, wethIsTokenA ? address(tokenB) : address(tokenA), tokensOut);
    }

    // Swap token sang ETH
    function swapExactTokenForETH(address inputToken, uint256 amountIn, uint256 minETHOut) external returns (uint256 ethOut) {
        require(inputToken == address(tokenA) || inputToken == address(tokenB), "Invalid token");
        require(msg.sender != address(0), "Invalid sender");
        require(amountIn > 0, "AmountIn > 0");

        bool wethIsTokenA = address(tokenA) == address(WETH);
        require(address(tokenA) == inputToken || address(tokenB) == inputToken, "Input token not in pair");
        require(address(tokenA) == address(WETH) || address(tokenB) == address(WETH), "WETH not in pair");

        IERC20 inToken = IERC20(inputToken);
        IERC20 outToken = wethIsTokenA ? tokenB : tokenA;

        uint256 reserveIn = inputToken == address(tokenA) ? reserveA : reserveB;
        uint256 reserveOut = inputToken == address(tokenA) ? reserveB : reserveA;

        require(inToken.transferFrom(msg.sender, address(this), amountIn), "Transfer in failed");

        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_PERCENT) / FEE_DENOMINATOR;

        ethOut = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
        require(ethOut >= minETHOut, "Insufficient ETH out");

        // Rút ETH từ WETH
        WETH.withdraw(ethOut);

        (bool sent,) = msg.sender.call{value: ethOut}("");
        require(sent, "ETH transfer failed");

        _updateReserves();

        emit Swap(msg.sender, inputToken, amountIn, address(WETH), ethOut);
    }

    // Swap token sang token (không ETH)
    function swap(address inputToken, uint256 amountIn, uint256 minOut) external returns (uint256 amountOut) {
        require(inputToken == address(tokenA) || inputToken == address(tokenB), "Invalid input token");
        require(amountIn > 0, "AmountIn > 0");

        IERC20 inToken = IERC20(inputToken);
        IERC20 outToken = inputToken == address(tokenA) ? tokenB : tokenA;

        uint256 reserveIn = inputToken == address(tokenA) ? reserveA : reserveB;
        uint256 reserveOut = inputToken == address(tokenA) ? reserveB : reserveA;

        require(inToken.transferFrom(msg.sender, address(this), amountIn), "Transfer in failed");

        uint256 amountInWithFee = amountIn * (FEE_DENOMINATOR - FEE_PERCENT) / FEE_DENOMINATOR;

        amountOut = (amountInWithFee * reserveOut) / (reserveIn + amountInWithFee);
        require(amountOut >= minOut, "Insufficient output amount");

        require(outToken.transfer(msg.sender, amountOut), "Transfer out failed");

        _updateReserves();

        emit Swap(msg.sender, inputToken, amountIn, address(outToken), amountOut);
    }

    // Hàm tiện ích tính căn bậc 2 (sqrt)
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

    // Hàm tiện ích lấy min trong 2 số
    function min(uint x, uint y) internal pure returns (uint) {
        return x < y ? x : y;
    }
    event Received(address indexed sender, uint256 value);
    event FallbackCalled(address indexed sender, uint256 value, bytes data);
    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    // Gọi sai hàm hoặc gửi ETH có data
    fallback() external payable {
        emit FallbackCalled(msg.sender, msg.value, msg.data);
    }
}
