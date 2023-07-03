`timescale 1ns / 1ps
module level_6_gen #(
    parameter DATA_WIDTH=8
)(
    input clk,
    input rst_n,
    input [64*DATA_WIDTH-1:0] idata,
    input ivalid,
    output reg [64*DATA_WIDTH-1:0] odata,
    output reg ovalid
    );
    
    localparam S1 =1'b0;
    localparam S2 =1'b1;
    
    reg cs,ns;
    reg [32*DATA_WIDTH-1:0] buffer1,buffer2;
    reg [5:0] cnt;
    
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
                if(cnt<63)
                    ns = S2;
                else
                    ns = S1;
            end
        endcase
    end
    
    always@(posedge clk or negedge rst_n)begin
        if(!rst_n)begin
            odata <= 'd0;
            buffer1 <= 'd0;
            buffer2 <= 'd0;
            ovalid <= 'b0;
            cnt <= 'd0;
        end
        else if(cs == S1)begin
            odata <= 'd0;
            buffer1 <= idata[0*DATA_WIDTH+:32*DATA_WIDTH];
            buffer2 <= idata[32*DATA_WIDTH+:32*DATA_WIDTH];
            ovalid <= 'b0;
            cnt <= 'd0;
        end
        else begin
            if(cnt == 63)
                ovalid <= 'b1;
            else
                ovalid <= 'b0;
            cnt <= cnt + 1;
            if(buffer1[31*DATA_WIDTH+:DATA_WIDTH]>buffer2[31*DATA_WIDTH+:DATA_WIDTH])begin
                odata <= {odata[0+:63*DATA_WIDTH],buffer1[31*DATA_WIDTH+:DATA_WIDTH]};
                buffer1 <= buffer1 << DATA_WIDTH;
            end
            else begin
                odata <= {odata[0+:63*DATA_WIDTH],buffer2[31*DATA_WIDTH+:DATA_WIDTH]};
                buffer2 <= buffer2 << DATA_WIDTH;
            end
        end
    end
    
endmodule