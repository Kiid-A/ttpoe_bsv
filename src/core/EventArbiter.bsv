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
    method Bool has_event();
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

    Reg#(Bool) dbg_tx_seen  <- mkReg(False);
    Reg#(Bool) dbg_state    <- mkReg(False);
    Reg#(UInt#(16)) dbg_cycle <- mkReg(0);

    rule rl_dbg_state (!dbg_state);
        dbg_state <= True;
        $display("[ARB] rx_q.notEmpty=%0d tx_q.notEmpty=%0d ak_q.notEmpty=%0d in_q.notEmpty=%0d",
                 pack(rx_q.notEmpty), pack(tx_q.notEmpty), pack(ak_q.notEmpty), pack(in_q.notEmpty));
    endrule

    rule rl_dbg_tx (tx_q.notEmpty && !dbg_tx_seen);
        dbg_tx_seen <= True;
        $display("[ARB] tx_q.notEmpty=1");
    endrule

    rule rl_dbg_queues;
        dbg_cycle <= dbg_cycle + 1;
        if ((dbg_cycle % 5) == 0) begin
            $display("[ARB][DBG] rx=%0d tx=%0d ak=%0d in=%0d",
                     pack(rx_q.notEmpty), pack(tx_q.notEmpty), pack(ak_q.notEmpty), pack(in_q.notEmpty));
        end
    endrule

    // =====================================================================
    // 接口方法连线
    // =====================================================================
    method Action enq_rx_event(EventReq req);
        $display("[ARB] enq RX kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        rx_q.enq(req);
    endmethod

    method Action enq_tx_event(EventReq req);
        $display("[ARB] enq TX kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        tx_q.enq(req);
    endmethod

    method Action enq_ak_event(EventReq req);
        $display("[ARB] enq AK kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        ak_q.enq(req);
    endmethod

    method Action enq_in_event(EventReq req);
        $display("[ARB] enq IN kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        in_q.enq(req);
    endmethod

    method Bool has_event();
        return (tx_q.notEmpty || rx_q.notEmpty || ak_q.notEmpty || in_q.notEmpty);
    endmethod

    // 弹出被仲裁器选中的事件 (TX 优先)
    method ActionValue#(EventReq) deq_event() if (tx_q.notEmpty || rx_q.notEmpty || ak_q.notEmpty || in_q.notEmpty);
        EventReq req = ?;
        if (tx_q.notEmpty) begin
            req = tx_q.first; tx_q.deq;
            $display("[ARB] deq TX kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        end
        else if (rx_q.notEmpty) begin
            req = rx_q.first; rx_q.deq;
            $display("[ARB] deq RX kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        end
        else if (ak_q.notEmpty) begin
            req = ak_q.first; ak_q.deq;
            $display("[ARB] deq AK kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        end
        else begin
            req = in_q.first; in_q.deq;
            $display("[ARB] deq IN kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        end
        return req;
    endmethod

endmodule

endpackage: EventArbiter