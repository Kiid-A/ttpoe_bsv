// =========================================================================
// File: src/core/TimerArray.bsv
// Description: TTPoE 硬件计时器阵列 (支持 2-Way 双路哈希扩展)
// =========================================================================

package TimerArray;

import RegFile::*;
import FIFOF::*;
import GetPut::*;
import TTPoE_Types::*;

// =========================================================================
// 定时器 SRAM 存储条目与指令结构
// =========================================================================
typedef struct {
    Bool     active;       
    Bit#(10) ticks_left;   
    Bit#(64) kid;          
} TimerEntry deriving (Bits, Eq, FShow);

typedef enum { CMD_START, CMD_STOP } TimerCmdType deriving (Bits, Eq);

typedef struct {
    TimerCmdType cmd;
    Bit#(64)     kid;
    Bit#(1)      way_idx;  // 【修正点】：必须包含 Way 索引以防覆盖
    Bit#(10)     val;      
} TimerCmd deriving (Bits, Eq);

// =========================================================================
// 硬件接口
// =========================================================================
interface TimerArray_Ifc;
    method Action start_timer(Bit#(64) kid, Bit#(1) way_idx, Bit#(10) timeout_ms);
    method Action stop_timer(Bit#(64) kid, Bit#(1) way_idx);
    method Action tick_1ms(); 
    interface Get#(EventReq) timeout_event_out;
endinterface

// =========================================================================
// 模块实现
// =========================================================================
(* synthesize *)
module mkTimerArray(TimerArray_Ifc);

    // 【修正点】：SRAM 深度扩展为 512，地址线 9-bit
    RegFile#(Bit#(9), TimerEntry) timer_sram <- mkRegFileFull();
    FIFOF#(TimerCmd) cmd_q     <- mkFIFOF;
    FIFOF#(EventReq) timeout_q <- mkFIFOF;

    Reg#(Bool)    scan_active <- mkReg(False);
    Reg#(Bit#(9)) scan_idx    <- mkReg(0); // 【修正点】：扫描指针同步升级为 9-bit

    function Bit#(8) hash_kid(Bit#(64) kid);
        return truncate(kid); 
    endfunction

    // Rule 1: 处理控制指令
    rule rl_process_cmds (cmd_q.notEmpty());
        let req = cmd_q.first(); 
        cmd_q.deq();
        
        // 【修正点】：物理地址 = 8位Hash拼接1位Way索引
        Bit#(9) addr = {hash_kid(req.kid), req.way_idx}; 
        
        if (req.cmd == CMD_START) begin
            timer_sram.upd(addr, TimerEntry { active: True, ticks_left: req.val, kid: req.kid });
        end 
        else begin
            TimerEntry entry = timer_sram.sub(addr);
            entry.active = False;
            timer_sram.upd(addr, entry);
        end
    endrule

    // Rule 2: 顺序扫描器 (Scanner)
    rule rl_scan_timers (scan_active && !cmd_q.notEmpty());
        TimerEntry entry = timer_sram.sub(scan_idx);
        
        if (entry.active) begin
            if (entry.ticks_left <= 1) begin
                entry.active = False;
                timeout_q.enq(EventReq { kid: entry.kid, event_type: EV_INQ_TIMEOUT });
            end 
            else begin
                entry.ticks_left = entry.ticks_left - 1;
            end
            timer_sram.upd(scan_idx, entry);
        end

        // 【修正点】：扫描到 511 时重置
        if (scan_idx == 511) begin
            scan_active <= False; 
        end
        scan_idx <= scan_idx + 1;
    endrule

    method Action start_timer(Bit#(64) kid, Bit#(1) way_idx, Bit#(10) timeout_ms);
        cmd_q.enq(TimerCmd { cmd: CMD_START, kid: kid, way_idx: way_idx, val: timeout_ms });
    endmethod

    method Action stop_timer(Bit#(64) kid, Bit#(1) way_idx);
        cmd_q.enq(TimerCmd { cmd: CMD_STOP, kid: kid, way_idx: way_idx, val: 0 }); 
    endmethod

    method Action tick_1ms() if (!scan_active);
        scan_active <= True;
        scan_idx    <= 0;
    endmethod

    interface timeout_event_out = toGet(timeout_q);
endmodule

endpackage: TimerArray