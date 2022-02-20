pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

// !!!!중요!!!!: 로직이 잘 이해가 안 갈 경우,
// https://github.com/Uniswap/v2-periphery/blob/master/contracts/UniswapV2Router02.sol
// 위 컨트랙트와 함께 봐야 함. 일단 토큰을 먼저 보내고, 코어에서는 정산만 하고 있다.

// 이 때 만드는 페어(풀)의 ERC20 토큰은 LP Token이다. 갖고 있으면 swap fee를 나눠준다.
contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath  for uint;
    using UQ112x112 for uint224;

    uint public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    uint112 private reserve0;           // uses single storage slot, accessible via getReserves
    uint112 private reserve1;           // uses single storage slot, accessible via getReserves
    uint32  private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint public price0CumulativeLast;
    uint public price1CumulativeLast;
    // reserve0 * reserve1, as of immediately after the most recent liquidity event
    uint public kLast;

    uint private unlocked = 1;

    // atomicity를 보장하기 위한 lock을 구현한 것.
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves() public view returns (
        uint112 _reserve0, uint112 _reserve1, uint32 _blockTimestampLast
        ) {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(address token, address to, uint value) private {
        (bool success, bytes memory data) =
            // 별 건 아니고 gas fee 아끼는 테크닉이다.
            token.call(abi.encodeWithSelector(SELECTOR, to, value));
        require(
            // 백서에도 나와있는데, ERC 20 표준을 안 따르는 애들(BNB, USDT)이
            // transfer 성공 이후에 아무 것도 return을 안 한다.
            // 그래서 data.length == 0 도 허용을 하는 것이다.
            success && (data.length == 0 || abi.decode(data, (bool))),
            'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint amount0, uint amount1);
    event Burn(address indexed sender, uint amount0, uint amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint amount0In,
        uint amount1In,
        uint amount0Out,
        uint amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    // mint 등 유저가 이벤트를 완료할 때마다 전체 풀의 정보를 업데이트해준다.
    // update reserves and, on the first call per block, price accumulators
    function _update(
        uint balance0, uint balance1, uint112 _reserve0, uint112 _reserve1
        ) private {
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1),
            'UniswapV2: OVERFLOW');

        // 이 아래의 culmative는 price orcale을 위한 것이다.
        // blockTimestamp는 이더리움 체인 전체의 전역변수임. 그냥 읽어올 수 있음. unix time임.
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            price0CumulativeLast +=
                uint(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast +=
                uint(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }

        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // 아래의 mintFee는 백서의 2.4 Protocol fee 부분을 읽고 와야 이해가 됨.
    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // 이런 식으로 다른 컨트랙트의 함수를 호출할 수 있음.
        // 크립토좀비의 ZombiFeeding.sol에서 이미 학습했다.
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                // 백서의 (7)식임.
                uint rootK = Math.sqrt(uint(_reserve0).mul(_reserve1));
                uint rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    uint numerator = totalSupply.mul(rootK.sub(rootKLast));
                    uint denominator = rootK.mul(5).add(rootKLast);
                    uint liquidity = numerator / denominator;
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // mint는 스왚의 대상이 되는 토큰 쌍을 공급하고 LP token을 받아가는 것이다.
    // this low-level function should be called from a contract
    // which performs important safety checks
    function mint(address to) external lock returns (uint liquidity) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        uint balance0 = IERC20(token0).balanceOf(address(this));
        uint balance1 = IERC20(token1).balanceOf(address(this));
        // ---------------****** 중요!!! ******----------------------
        // 일단 periphery.sol에서 토큰 쌍을 이 LP 풀로 먼저 보내고, 차액을 통해서 이 유저가 얼마 넣었는지를 계산함.
        uint amount0 = balance0.sub(_reserve0);
        uint amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        // 여기서 totalSupply는 이 컨트랙트가 상속받은 UniswapV2ERC20, 즉 LP Token의 totalSupply다.
        // gas savings, must be defined here since totalSupply can update in _mintFee
        uint _totalSupply = totalSupply;
        // 이 pool이 최초로 만들어진 경우
        if (_totalSupply == 0) {
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            // 공격 방지. 한 단위의 가치가 너무 커지게 하는 공격 막기 위함.
            // permanently lock the first MINIMUM_LIQUIDITY tokens
           _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            // 풀의 reserve가 늘어난만큼을 계산해서 유동성을 늘려준다.
            // 백서의 (12)식임.
            // amount0 = Xdeposited,_totalSupply는 Sstarting, _reserve0는 Xstarting.
            liquidity = Math.min(
                amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        // 이 _mint는 상속한 ERC20 token (LP token)을 mint하는 것임.
        _mint(to, liquidity);

        _update(balance0, balance1, _reserve0, _reserve1);
        // reserve0 and reserve1 are up-to-date
        if (feeOn) kLast = uint(reserve0).mul(reserve1);
        emit Mint(msg.sender, amount0, amount1);
    }

    // LP token을 돌려주고 토큰 쌍들을 돌려받아서 유동성 공급을 해제하는 함수다.
    // this low-level function should be called from a contract
    // which performs important safety checks
    function burn(address to) external lock returns (uint amount0, uint amount1) {
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        address _token0 = token0;                                // gas savings
        address _token1 = token1;                                // gas savings
        uint balance0 = IERC20(_token0).balanceOf(address(this));
        uint balance1 = IERC20(_token1).balanceOf(address(this));

        // ---------------****** 중요!!! ******----------------------
        // 일단 periphery router에서 LP token을 LP 풀로 먼저 보내고, 차액을 통해서 이 유저가 얼마 넣었는지를 계산함.
        // 이 LP pool(pair) Token은 pool contract가 소유하는 게 아니라 공급한 유저가 소유하는 것이다.
        // 그런데 컨트랙트에 LP token이 있다는 것은 periphery에서 유저가 일부러 보낸 것 외에 다른 경우가 없다.
        // 따라서 아래의 변수 liquidity는 방금 유저가 넣어준 LP token이다.
        uint liquidity = balanceOf[address(this)];

        // mint할 때와 마찬가지로 옵션이 켜져있다면 1/6을 프로토콜 피로 걷어간다.
        bool feeOn = _mintFee(_reserve0, _reserve1);

        // gas savings, must be defined here since totalSupply can update in _mintFee
        uint _totalSupply = totalSupply;

        // X토큰이 100개 있고, LP 토큰 총 발행량이 10개인데 유저가 LP token 1개 돌려주면 X token 10개 돌려줘야 함.
        amount0 = liquidity.mul(balance0) / _totalSupply;
        amount1 = liquidity.mul(balance1) / _totalSupply;

        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');

        // 정산: LP token은 소각해버리는 대신 토큰 쌍들을 돌려준다. (비율은 달라질 수 있다: Impernanat Loss 문제)
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);

        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        _update(balance0, balance1, _reserve0, _reserve1);
        // reserve0 and reserve1 are up-to-date
        if (feeOn) kLast = uint(reserve0).mul(reserve1);
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // 일단 토큰을 먼저 보내고, 그 이후에 그에 상응하는 페어된 토큰을 받는다.
    // 토큰 먼저 보내는 건 Rotuer에서 했고, 여기서는 받는 것만 한다.
    // 보내는 건 간단한데 그냥 안전장치 체크 같은 게 많다. 코드 복잡해 보인다고 겁 먹지 않아도 된다.
    // 받는 양도 Router에서 이미 계산해놨다.
    // 보내는 함수는 UniswapV2Router02의 swapExactTokensForTokens 함수 참조.
    // this low-level function should be called from a contract
    // which performs important safety checks
    function swap(
        uint amount0Out, uint amount1Out, address to, bytes calldata data
        ) external lock {
        require(amount0Out > 0 || amount1Out > 0, '
            UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1,) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1,
            'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint balance0;
        uint balance1;
        { // scope for _token{0,1}, avoids stack too deep errors
        address _token0 = token0;
        address _token1 = token1;
        require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
        // optimistically transfer tokens
        if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out);
        // optimistically transfer tokens
        if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out);
        if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(
            msg.sender, amount0Out, amount1Out, data);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        }
        uint amount0In = balance0 > _reserve0 - amount0Out ?
            balance0 - (_reserve0 - amount0Out) : 0;
        uint amount1In = balance1 > _reserve1 - amount1Out ?
            balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        { // scope for reserve{0,1}Adjusted, avoids stack too deep errors
        uint balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
        uint balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
        require(balance0Adjusted.mul(balance1Adjusted) >=
            uint(_reserve0).mul(_reserve1).mul(1000**2), 'UniswapV2: K');
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)),
        IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
// optimistically transfer tokens