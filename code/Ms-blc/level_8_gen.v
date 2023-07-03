`timescale 1ns / 1ps
module level_8_gen #(
    parameter DATA_WIDTH=8
)(
    input clk,
    input rst_n,
    input [256*DATA_WIDTH-1:0] idata,
    input ivalid,
    output reg [DATA_WIDTH-1:0] odata,
    output reg ovalid
    );
    
    localparam S1 =1'b0;
    localparam S2 =1'b1;
    
    reg cs,ns;
    reg [128*DATA_WIDTH-1:0] buffer1,buffer2;
    reg [7:0] cnt;
    reg [2*DATA_WIDTH-1:0] med;
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)
            cs <= S1;
        else
            cs <= ns;
    end
    
    always@(*)begin
        case(cs)
            S1:begin
                if(ivalid)
                    ns = S2;
                else
                    ns = S1;
            end
            S2:begin
                if(cnt<129)
                    ns = S2;
                else
                    ns = S1;
            end
        endcase
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            med <= 'd0;
            buffer1 <= 'd0;
            buffer2 <= 'd0;
            ovalid <= 'b0;
            cnt <= 'd0;
            odata <= 'd0;
        end
        else if(cs == S1)begin
            med <= 'd0;
            buffer1 <= idata[0*DATA_WIDTH+:128*DATA_WIDTH];
            buffer2 <= idata[128*DATA_WIDTH+:128*DATA_WIDTH];
            ovalid <= 'b0;
            cnt <= 'd0;
            odata <= 'd0;
        end
        else begin
            if(cnt == 129)begin
                ovalid <= 'b1;
                odata <= (med[0+:DATA_WIDTH] + med[DATA_WIDTH+:DATA_WIDTH]) / 2;
            end
            else begin
                ovalid <= 'b0;
                odata <= 'd0;
            end
            cnt <= cnt + 1;
            if(buffer1[127*DATA_WIDTH+:DATA_WIDTH]>buffer2[127*DATA_WIDTH+:DATA_WIDTH])begin
                med <= {med[0+:DATA_WIDTH],buffer1[127*DATA_WIDTH+:DATA_WIDTH]};
                buffer1 <= buffer1 << DATA_WIDTH;
            end
            else begin
                med <= {med[0+:DATA_WIDTH],buffer2[127*DATA_WIDTH+:DATA_WIDTH]};
                buffer2 <= buffer2 << DATA_WIDTH;
            end
        end
    end
    
endmodule