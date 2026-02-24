// =========================================================================
// File: src/top/TTPoE_Top.bsv
// Description: TTPoE 顶层硬件模块 (Top Level)
// =========================================================================

package TTPoE_Top;

import FIFOF::*;
import GetPut::*;
import Connectable::*;

import TTPoE_Types::*;
import TTPoE_Headers::*;
import FSM_Engine::*;
import TMU::*;
import EventArbiter::*;
import TimerArray::*;
import RX_Parser::*;
import TX_Builder::*;

interface TTPoE_Top_Ifc;
    interface Put#(Raw_MAC_Frame) mac_rx_in;  
    interface Get#(Raw_MAC_Frame) mac_tx_out; 
    interface Get#(Raw_MAC_Frame) noc_rx_out; 
    interface Put#(Raw_MAC_Frame) noc_tx_in;  
    method Action host_ctrl_request(EventReq req);
endinterface

(* synthesize *)
module mkTTPoE_Top(TTPoE_Top_Ifc);

    // 1. 实例化子模块
    TMU_Ifc          tmu         <- mkTMU();
    EventArbiter_Ifc arbiter     <- mkEventArbiter();
    TimerArray_Ifc   timer_array <- mkTimerArray();
    RX_Parser_Ifc    rx_parser   <- mkRX_Parser(tmu);
    TX_Builder_Ifc   tx_builder  <- mkTX_Builder(tmu);

    // 2. 内部连线
    rule rl_route_rx_events;
        let req <- rx_parser.rx_event_out.get();
        arbiter.enq_rx_event(req);
    endrule

    rule rl_route_timer_events;
        let req <- timer_array.timeout_event_out.get();
        arbiter.enq_in_event(req);
    endrule


    // 3. 核心心脏脉动 (Main FSM Pipeline)
    rule rl_main_fsm_pipeline (arbiter.has_event);
        EventReq req <- arbiter.deq_event();
        TagContext ctx = tmu.read_context(req.kid);
        FSM_Output out = fsm_lookup(ctx.state, req.event_type);

        $display("[FSM] kid=0x%0h evt=%0d curr=%0d next=%0d resp=%0d", req.kid, pack(req.event_type), pack(ctx.state), pack(out.next_state), pack(out.response));

        if (out.next_state != ST_STAY && out.next_state != ctx.state) begin
            ctx.state = out.next_state;
            ctx.kid   = req.kid;
            if (out.next_state == ST_CLOSED) begin
                ctx.valid = False;
            end
            else begin
                ctx.valid = True;
            end
            tmu.write_context(req.kid, ctx);

            // 【修正点】：将 ctx.way_idx 精准传给定时器，防止错杀覆盖
            if (out.next_state == ST_OPEN_SENT) begin
                timer_array.start_timer(req.kid, ctx.way_idx, 10'd250); 
            end
            else if (out.next_state == ST_CLOSED || out.next_state == ST_OPEN) begin
                timer_array.stop_timer(req.kid, ctx.way_idx);           
            end
        end

        if (out.response != RS_NONE && out.response != RS_ILLEGAL && out.response != RS_STALL) begin
            $display("[FSM] generate_ctrl_pkt resp=%0d kid=0x%0h", pack(out.response), req.kid);
            tx_builder.generate_ctrl_pkt(req.kid, out.response);
        end
    endrule

    // 4. 对外接口映射
    interface mac_rx_in  = rx_parser.mac_rx_in;
    interface mac_tx_out = tx_builder.mac_tx_out;
    interface noc_rx_out = rx_parser.noc_payload_out;
    interface noc_tx_in  = tx_builder.noc_tx_in;
    
    method Action host_ctrl_request(EventReq req);
        $display("[TOP] host_ctrl_request kid=0x%0h evt=%0d", req.kid, pack(req.event_type));
        arbiter.enq_tx_event(req);
    endmethod

endmodule

endpackage: TTPoE_Top