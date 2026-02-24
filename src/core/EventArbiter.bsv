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


    // =====================================================================
    // 接口方法连线
    // =====================================================================
    method Action enq_rx_event(EventReq req);
        rx_q.enq(req);
    endmethod

    method Action enq_tx_event(EventReq req);
        $display("[ARB] enq TX kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        tx_q.enq(req);
    endmethod

    method Action enq_ak_event(EventReq req);
        ak_q.enq(req);
    endmethod

    method Action enq_in_event(EventReq req);
        in_q.enq(req);
    endmethod

    method Bool has_event();
        return (tx_q.notEmpty || rx_q.notEmpty || ak_q.notEmpty || in_q.notEmpty);
    endmethod

    // 弹出被仲裁器选中的事件 (TX 优先)
    method ActionValue#(EventReq) deq_event()
        if (tx_q.notEmpty || rx_q.notEmpty || ak_q.notEmpty || in_q.notEmpty);
        if (tx_q.notEmpty) begin
            let req = tx_q.first;
            tx_q.deq;
            $display("[ARB] deq TX kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
            return req;
        end
        else if (rx_q.notEmpty) begin
            let req = rx_q.first;
            rx_q.deq;
            $display("[ARB] deq RX kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
            return req;
        end
        else if (ak_q.notEmpty) begin
            let req = ak_q.first;
            ak_q.deq;
            $display("[ARB] deq AK kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
            return req;
        end
        else begin
            let req = in_q.first;
            in_q.deq;
            $display("[ARB] deq IN kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
            return req;
        end
    endmethod

endmodule

endpackage: EventArbiter