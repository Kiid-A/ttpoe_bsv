// 组合逻辑实现状态机

package FSM_Engine;

import TTPoE_Types::*;


// FSM 输出数据结构
typedef struct {
    TTPoE_Response response;
    TTPoE_State    next_state;
} FSM_Output deriving (Bits, Eq, FShow);

// 状态机查表函数
function FSM_Output fsm_lookup(TTPoE_State curr_state, TTPoE_Event event_type);
    
    // 初始化默认输出：遇到未定义组合时，保持原状态，抛出非法动作
    FSM_Output out;
    out.response   = RS_ILLEGAL;
    out.next_state = ST_STAY;

    // 使用 tuple2 将两个输入打包，利用 BSV 的 matches 进行二维矩阵模式匹配
    case (tuple2(curr_state, event_type)) matches
        
        // =================================================================
        // 1. 主机端发起的 TXQ 事件 (Host -> Network)
        // =================================================================
        {ST_CLOSED, EV_TXQ_TTP_OPEN}: begin
            out.response   = RS_OPEN;
            out.next_state = ST_OPEN_SENT;
        end
        {ST_OPEN, EV_TXQ_TTP_PAYLOAD}: begin
            out.response   = RS_PAYLOAD;
            out.next_state = ST_STAY;
        end
        {ST_OPEN_SENT, EV_TXQ_TTP_PAYLOAD}: begin
            out.response   = RS_STALL;     // 硬件反压：建链中，拒绝发数据
            out.next_state = ST_STAY;
        end
        {ST_CLOSED, EV_TXQ_TTP_PAYLOAD}: begin
            out.response   = RS_STALL;     // 硬件反压：未建链，拒绝发数据
            out.next_state = ST_STAY;
        end
        {ST_OPEN, EV_TXQ_TTP_CLOSE}: begin
            out.response   = RS_CLOSE;
            out.next_state = ST_CLOSE_SENT;
        end

        // =================================================================
        // 2. 网络端接收的 RXQ 事件 (Network -> Host)
        // =================================================================
        {ST_CLOSED, EV_RXQ_TTP_OPEN}: begin
            out.response   = RS_NONE;
            out.next_state = ST_OPEN_RECD; // 转入等待 TMU 分配资源阶段
        end
        {ST_OPEN_SENT, EV_RXQ_TTP_OPEN}: begin
            out.response   = RS_OPEN_ACK;  // 交错建链 (Passing Ships)
            out.next_state = ST_OPEN;
        end
        {ST_OPEN_SENT, EV_RXQ_TTP_OPEN_ACK}: begin
            out.response   = RS_NONE;
            out.next_state = ST_OPEN;      // 握手成功
        end
        {ST_OPEN_SENT, EV_RXQ_TTP_OPEN_NACK}: begin
            out.response   = RS_NOC_FAIL;  // 对方拒绝建链
            out.next_state = ST_CLOSED;
        end
        {ST_OPEN, EV_RXQ_TTP_PAYLOAD}: begin
            out.response   = RS_ACK;       // 数据合法，要求回复 ACK
            out.next_state = ST_STAY;
        end
        {ST_CLOSED, EV_RXQ_TTP_PAYLOAD}: begin
            out.response   = RS_NACK_NOLINK; // 异常包，警告对方无连接
            out.next_state = ST_STAY;
        end
        {ST_OPEN, EV_RXQ_TTP_CLOSE}: begin
            out.response   = RS_CLOSE_XACK;
            out.next_state = ST_CLOSE_RECD;  // 准备排空队列
        end
        {ST_CLOSE_SENT, EV_RXQ_TTP_CLOSE_ACK}: begin
            out.response   = RS_NOC_END;
            out.next_state = ST_CLOSED;      // 挥手完成
        end

        // =================================================================
        // 3. 内部管理与定时器 INQ 事件 (Self-Managed)
        // =================================================================
        {ST_OPEN_RECD, EV_INQ_ALLOC_TAG}: begin
            out.response   = RS_OPEN_ACK;  // TMU资源分配成功
            out.next_state = ST_OPEN;
        end
        {ST_OPEN_RECD, EV_INQ_NO_TAG}: begin
            out.response   = RS_OPEN_NACK; // TMU资源满载，拒绝连接
            out.next_state = ST_CLOSED;
        end
        {ST_OPEN_SENT, EV_INQ_TIMEOUT}: begin
            out.response   = RS_OPEN;      // 握手超时，重发 OPEN
            out.next_state = ST_OPEN_SENT;
        end
        {ST_OPEN, EV_INQ_TIMEOUT}: begin
            out.response   = RS_REPLAY_DATA; // Payload 确认超时，触发底层重传
            out.next_state = ST_STAY;
        end
        {ST_OPEN, EV_INQ_VICTIM}: begin
            out.response   = RS_CLOSE;       // 哈希冲突，被 TMU 选中为受害者驱逐
            out.next_state = ST_CLOSE_SENT;
        end
        {ST_CLOSE_RECD, EV_INQ_YES_QUIESCED}: begin
            out.response   = RS_CLOSE_ACK;   // 发送队列已排空，允许关闭
            out.next_state = ST_CLOSED;
        end
        {ST_CLOSE_RECD, EV_INQ_NOT_QUIESCED}: begin
            out.response   = RS_CLOSE_XACK;  // 队列未排空，让对端继续等
            out.next_state = ST_STAY;
        end
        
        // 忽略其他无关紧要的事件组合
        default: begin
            out.response   = RS_NONE;
            out.next_state = ST_STAY;
        end

    endcase

    // 如果 next_state 是 ST_STAY，意味着不改变状态
    // 我们将其直接返回 ST_STAY 让外部模块知道不需要写回 SRAM
    return out;

endfunction

endpackage: FSM_Engine