`timescale 1ns / 1ps
module med_w #(
    parameter DATA_WIDTH = 8
)(
    input [3*DATA_WIDTH-1:0] data,
    output [DATA_WIDTH-1:0] med
    );
    
    wire [DATA_WIDTH-1:0] a,b,c;
    wire [DATA_WIDTH-1:0] temp_max, temp_min, temp_med;
    reg [DATA_WIDTH-1:0] temp_max_r, temp_med_r;
    
    assign a = data[3*DATA_WIDTH-1:2*DATA_WIDTH];
    assign b = data[2*DATA_WIDTH-1:1*DATA_WIDTH];
    assign c = data[1*DATA_WIDTH-1:0*DATA_WIDTH];
    assign {temp_max, temp_min} = a > b ? {a,b} : {b,a};
    assign temp_med= temp_min < c ? c : temp_min;
    assign med = temp_max > temp_med ?  temp_med : temp_max;

endmodule
