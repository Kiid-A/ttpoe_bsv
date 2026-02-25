// 连接上下文管理器

package TMU;

import RegFile::*;
import TTPoE_Types::*;
import TTPoE_Headers::*;


// Tag Context 数据结构
typedef struct {
    Bool        valid;      // 槽位是否有效
    Bit#(1)     way_idx;    // 双路标识位
    Bit#(64)    kid;        // 处理哈希冲突要用
    TTPoE_State state;      // 当前 3-bit 状态
    
    Bit#(32)    rx_seq_id;  // 期望接收的下一个序号 (用于校验接收包)
    Bit#(32)    tx_seq_id;  // 下一个要发送的序号 (发包时分配并递增)
    Bit#(32)    retire_id;  // 已被对端确认的序号 (用于释放本地内存)
} TagContext deriving (Bits, Eq, FShow);

// TMU 接口
interface TMU_Ifc;
    // --- 控制面接口 (供 FSM 与 Arbiter 查表和更新状态使用) ---
    method TagContext read_context(Bit#(64) kid);
    method Action     write_context(Bit#(64) kid, TagContext ctx);

    // --- 数据面接口 (供 RX_Parser 快车道使用，不走 FSM 直接校验) ---
    method Bool       check_rx_seq(Bit#(64) kid, Bit#(32) pkt_tx_seq);
    method Action     update_rx_seq(Bit#(64) kid); 

    // --- 数据面接口 (供 TX_Builder 组包使用) ---
    method ActionValue#(Bit#(32)) get_and_inc_tx_seq(Bit#(64) kid);
endinterface

// TMU 硬件模块设计
(* synthesize *)
module mkTMU(TMU_Ifc);
    RegFile#(Bit#(8), TagContext) bank0 <- mkRegFileFull();
    RegFile#(Bit#(8), TagContext) bank1 <- mkRegFileFull();

    // 简单的硬件 Hash 函数：取 KID 的高 8 位 (MAC LSB 的高字节) 作为索引
    function Bit#(8) hash_kid(Bit#(64) kid);
        return truncate(kid >> 56);
    endfunction

    // ---------------------------------------------------------------------
    // 接口方法实现
    // ---------------------------------------------------------------------

    // [控制面] 读出当前状态喂给 FSM
    method TagContext read_context(Bit#(64) kid);
        Bit#(8) addr = hash_kid(kid);

        // 双路搜索
        TagContext ctx0 = bank0.sub(addr);
        TagContext ctx1 = bank1.sub(addr);

        if (ctx0.valid && ctx0.kid == kid) begin
            return ctx0; // 命中路 0
        end 
        else if (ctx1.valid && ctx1.kid == kid) begin
            return ctx1; // 命中路 1
        end 
        else begin
            // 都没有命中 (Miss)。返回一个带有 ST_CLOSED 状态的空壳。
            return TagContext { 
                valid: False, way_idx: 0, kid: kid, 
                state: ST_CLOSED, rx_seq_id: 0, tx_seq_id: 0, retire_id: 0 
            };
        end
    endmethod

    // [控制面] FSM 决策完毕后，写回新状态
    method Action write_context(Bit#(64) kid, TagContext ctx);
        Bit#(8) addr = hash_kid(kid);
        
        if (ctx.way_idx == 0) begin
            bank0.upd(addr, ctx);
        end
        else begin
            bank1.upd(addr, ctx);
        end
    endmethod

    // [数据面 RX] 高速序列号校验
    method Bool check_rx_seq(Bit#(64) kid, Bit#(32) pkt_tx_seq);
        Bit#(8) addr = hash_kid(kid);
        
        TagContext ctx0 = bank0.sub(addr);
        TagContext ctx1 = bank1.sub(addr);
        
        Bool hit_way0 = (ctx0.valid && ctx0.kid == kid && ctx0.rx_seq_id == pkt_tx_seq);
        Bool hit_way1 = (ctx1.valid && ctx1.kid == kid && ctx1.rx_seq_id == pkt_tx_seq);
        
        return (hit_way0 || hit_way1);
    endmethod

    // [数据面 RX] 收到合法的 Payload，或者合法的控制包后，期望序号 + 1
    method Action update_rx_seq(Bit#(64) kid);
        Bit#(8) addr = hash_kid(kid);
        
        TagContext ctx0 = bank0.sub(addr);
        TagContext ctx1 = bank1.sub(addr);
        
        if (ctx0.valid && kid == ctx0.kid) begin
            ctx0.rx_seq_id = ctx0.rx_seq_id + 1; 
            bank0.upd(addr, ctx0);
        end
        else if (ctx1.valid && kid == ctx1.kid) begin
            ctx1.rx_seq_id = ctx1.rx_seq_id + 1; 
            bank1.upd(addr, ctx1);
        end
    endmethod

    // [数据面 TX] 硬件组装报文时，抓取当前的 tx_seq，并自动 + 1
    method ActionValue#(Bit#(32)) get_and_inc_tx_seq(Bit#(64) kid);
        Bit#(8) addr = hash_kid(kid);
        
        TagContext ctx0 = bank0.sub(addr);
        TagContext ctx1 = bank1.sub(addr);
        
        Bit#(32) current_tx = 0;

        if (ctx0.valid && kid == ctx0.kid) begin
            current_tx = ctx0.tx_seq_id;
            ctx0.tx_seq_id = current_tx + 1; 
            bank0.upd(addr, ctx0);
        end
        else if (ctx1.valid && kid == ctx1.kid) begin
            current_tx = ctx1.tx_seq_id;
            ctx1.tx_seq_id = current_tx + 1; 
            bank1.upd(addr, ctx1);
        end

        return current_tx;
    endmethod

endmodule

endpackage: TMU