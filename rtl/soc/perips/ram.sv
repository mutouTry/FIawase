 /*                                                                      
 Copyright 2020 Blue Liang, liangkangnan@163.com
                                                                         
 Licensed under the Apache License, Version 2.0 (the "License");         
 you may not use this file except in compliance with the License.        
 You may obtain a copy of the License at                                 
                                                                         
     http://www.apache.org/licenses/LICENSE-2.0                          
                                                                         
 Unless required by applicable law or agreed to in writing, software    
 distributed under the License is distributed on an "AS IS" BASIS,       
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and     
 limitations under the License.                                          
 */

`include "defines.svh"


module ram #(
    parameter DP = 4096
    )(
    input  wire        clk_i,
    input  wire        rst_ni,

    input  wire        req_i,
    input  wire        we_i,
    input  wire [ 3:0] be_i,
    input  wire [31:0] addr_i,
    input  wire [31:0] data_i,
    output wire        gnt_o,
    output wire        rvalid_o,
	output wire [31:0] data_o
    );

    reg rvalid_q;
    wire[31:0] addr;

    assign addr = {6'h0, addr_i[27:2]};
    assign gnt_o = req_i;

    always @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            rvalid_q <= 1'b0;
            //gnt_o <= 1'b0;
        end else begin
            rvalid_q <= req_i;
            //gnt_o  <= req_i;
        end
    end

    assign rvalid_o = rvalid_q;

`ifndef T22NM

    gen_ram #(
        .DP(DP),
        .DW(32),
        .MW(4),
        .AW(32)
    ) u_gen_ram(
        .clk(clk_i),
        .addr_i(addr),
        .data_i(data_i),
        .sel_i(be_i),
        .we_i(we_i),
        .data_o(data_o)
    );

`else

 wire [3:0] ben_i = ~be_i;

 sram_sp_8192x32 usram_sp_8192x32
 (  
    .q    (data_o), 
    .clk  (clk_i), 
    .cen  (!req_i), 
    .gwen (!we_i), 
    .a    (addr[12:0]), 
    .d    (data_i), 
    .wen  ({{8{ben_i[3]}},{8{ben_i[2]}},{8{ben_i[1]}},{8{ben_i[0]}}}), 
    .stov  (1'b0), 
    .ema   (3'b111), 
    .emaw  (2'b11), 
    .emas  (1'b1), 
    .ret1n (1'b1)
 );
 
`endif

endmodule
