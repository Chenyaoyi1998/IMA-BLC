`timescale 1ns / 1ps
module sort_mxx(
    input clk,
    input rst_n,
    input sort_valid,
    input [15:0] pixel_cnt,
    output reg o_valid
    );
    
    localparam IDEL = 2'b00;
    localparam LOAD_1 = 2'b01;
    localparam LOAD_2 = 2'b10;
    localparam CALCU = 2'b11;
    
    reg [1:0] cs,ns;
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            cs <= IDEL;
        else
            cs <= ns;
    end
    
    always@(*)begin
        case(cs)
            IDEL:begin
                if(sort_valid)
                    ns = LOAD_1;
                else
                    ns = IDEL;
            end
            LOAD_1:begin
                if(sort_valid)
                    ns = LOAD_2;
                else
                    ns = LOAD_1;
            end
            LOAD_2:begin
                if(sort_valid)
                    ns = CALCU;
                else
                    ns = LOAD_2;
            end
            CALCU:begin
                if(pixel_cnt=='d0)
                    ns = IDEL;
                else
                    ns = CALCU;
            end
            default:ns=IDEL;
        endcase
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            o_valid <= 1'b0;
        else if(ns == CALCU)
            o_valid <= sort_valid;
    end
endmodule
