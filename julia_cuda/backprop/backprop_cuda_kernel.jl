include("backprop_cuda.jl")

@target ptx function bpnn_layerforward_CUDA(input_cuda,
                                            output_hidden_cuda,
                                            input_hidden_cuda,
                                            hidden_partial_sum,
                                            inp, hid)
    by = blockIdx().y - 1
    tx = threadIdx().x - 1
    ty = threadIdx().y - 1

    index = (hid + 1) * HEIGHT * by + (hid + 1) * ty + tx + 1 + (hid + 1)
    index_in = HEIGHT * by + ty + 1

    input_node = @cuStaticSharedMem(Float32, HEIGHT)
    weight_matrix = @cuStaticSharedMem(Float32, (HEIGHT, WIDTH))

    if tx == 0
        input_node[ty + 1] = input_cuda[index_in + 1]
    end

    sync_threads()

    weight_matrix[tx + 1, ty + 1] = input_hidden_cuda[index + 1]

    sync_threads()

    weight_matrix[tx + 1, ty + 1] *= input_node[ty + 1]

    sync_threads()

    # TODO: Since HEIGHT is an integer, there might be a nicer way to express
    # i = 1:log2(HEIGHT) than what is currently used.
    for i = 1:Int32(CUDAnative.log2(Float32(HEIGHT)))
        power_two = CUDAnative.pow(2f0, Int32(i))
        if ty % power_two == 0
            weight_matrix[tx + 1, ty + 1] +=
                weight_matrix[tx + 1, ty + Int32(power_two / 2) + 1]
        end
        sync_threads()
    end

    input_hidden_cuda[index + 1] = weight_matrix[tx + 1, ty + 1]

    sync_threads()

    if tx == 0
        hidden_partial_sum[by * hid + ty + 1] = weight_matrix[ty + 1, tx + 1]
    end

    return nothing
end

@target ptx function bpnn_adjust_weights_cuda(delta, hid, ly, inp, w, oldw)
    by = blockIdx().y - 1
    tx = threadIdx().x - 1
    ty = threadIdx().y - 1

    index = (hid + 1) * HEIGHT * by + (hid + 1) * ty + tx + 2 + (hid + 1)
    index_y = HEIGHT * by + ty + 2
    index_x = tx + 2

    w[index] += Float32(ETA * delta[index_x] * ly[index_y] +
        MOMENTUM * oldw[index])
    oldw[index] = Float32(ETA * delta[index_x] * ly[index_y] +
        MOMENTUM * oldw[index])

    sync_threads()

    if ty == 0 && by == 0
        w[index_x] += Float32(ETA * delta[index_x] + MOMENTUM * oldw[index_x])
        oldw[index_x] = Float32(ETA * delta[index_x] + MOMENTUM * oldw[index_x])
    end

    return nothing
end
