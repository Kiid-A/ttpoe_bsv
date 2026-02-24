// Round-Robin Arbiter

package EventArbiter;

import FIFOF::*;
import TTPoE_Types::*;


// 事件仲裁器
interface EventArbiter_Ifc;
    // --- 生产者接口 (Producer) ---
    // 供网络层解析器、主机 NOC 接口、内部定时器等并行写入
    method Action enq_rx_event(EventReq req);
    method Action enq_tx_event(EventReq req);
    method Action enq_ak_event(EventReq req);
    method Action enq_in_event(EventReq req);

    // --- 消费者接口 (Consumer) ---
    // 供 FSM/顶层流水线单步弹出，绝对不会发生多源冲突
    method ActionValue#(EventReq) deq_event();
endinterface

(* synthesize *)
module mkEventArbiter(EventArbiter_Ifc);

    // 实例化四个带状态位 (notEmpty/notFull) 的硬件 FIFO
    // 在真实 FPGA/ASIC 中，FIFO 的深度可以根据拥塞需求配置，这里默认使用 2 深度的流线 FIFO
    FIFOF#(EventReq) rx_q <- mkFIFOF; // 网络接收事件
    FIFOF#(EventReq) tx_q <- mkFIFOF; // 主机发送事件
    FIFOF#(EventReq) ak_q <- mkFIFOF; // 内部确认事件
    FIFOF#(EventReq) in_q <- mkFIFOF; // 定时与资源管理事件

    // 输出汇聚 FIFO (缓冲仲裁结果给 FSM)
    FIFOF#(EventReq) out_q <- mkFIFOF;

    // 轮询令牌寄存器 (Token): 0=RX, 1=TX, 2=AK, 3=IN
    Reg#(Bit#(2)) turn <- mkReg(0);

    // =====================================================================
    // 核心 Rule: Round-Robin 硬件调度算法
    // 触发条件：只要任意一个输入队列有数据，且输出队列未满，该规则就会在时钟上升沿发射
    // =====================================================================
    rule rl_arbitrate (rx_q.notEmpty || tx_q.notEmpty || ak_q.notEmpty || in_q.notEmpty);
        
        // 硬件组合逻辑实现：严格轮询，防止饿死
        if (turn == 0) begin
            if      (rx_q.notEmpty) begin out_q.enq(rx_q.first); rx_q.deq; turn <= 1; end
            else if (tx_q.notEmpty) begin out_q.enq(tx_q.first); tx_q.deq; turn <= 2; end
            else if (ak_q.notEmpty) begin out_q.enq(ak_q.first); ak_q.deq; turn <= 3; end
            else if (in_q.notEmpty) begin out_q.enq(in_q.first); in_q.deq; turn <= 0; end
        end
        else if (turn == 1) begin
            if      (tx_q.notEmpty) begin out_q.enq(tx_q.first); tx_q.deq; turn <= 2; end
            else if (ak_q.notEmpty) begin out_q.enq(ak_q.first); ak_q.deq; turn <= 3; end
            else if (in_q.notEmpty) begin out_q.enq(in_q.first); in_q.deq; turn <= 0; end
            else if (rx_q.notEmpty) begin out_q.enq(rx_q.first); rx_q.deq; turn <= 1; end
        end
        else if (turn == 2) begin
            if      (ak_q.notEmpty) begin out_q.enq(ak_q.first); ak_q.deq; turn <= 3; end
            else if (in_q.notEmpty) begin out_q.enq(in_q.first); in_q.deq; turn <= 0; end
            else if (rx_q.notEmpty) begin out_q.enq(rx_q.first); rx_q.deq; turn <= 1; end
            else if (tx_q.notEmpty) begin out_q.enq(tx_q.first); tx_q.deq; turn <= 2; end
        end
        else begin // turn == 3
            if      (in_q.notEmpty) begin out_q.enq(in_q.first); in_q.deq; turn <= 0; end
            else if (rx_q.notEmpty) begin out_q.enq(rx_q.first); rx_q.deq; turn <= 1; end
            else if (tx_q.notEmpty) begin out_q.enq(tx_q.first); tx_q.deq; turn <= 2; end
            else if (ak_q.notEmpty) begin out_q.enq(ak_q.first); ak_q.deq; turn <= 3; end
        end
    endrule

    // =====================================================================
    // 接口方法连线
    // =====================================================================
    method Action enq_rx_event(EventReq req);
        rx_q.enq(req);
    endmethod

    method Action enq_tx_event(EventReq req);
        tx_q.enq(req);
    endmethod

    method Action enq_ak_event(EventReq req);
        ak_q.enq(req);
    endmethod

    method Action enq_in_event(EventReq req);
        in_q.enq(req);
    endmethod

    // 弹出被仲裁器选中的事件
    method ActionValue#(EventReq) deq_event();
        let req = out_q.first;
        out_q.deq;
        return req;
    endmethod

endmodule

endpackage: EventArbiter