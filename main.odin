#+feature dynamic-literals

package main
IS_SERVER :: #config(IS_SERVER, false)
package_size :: 100

import "core:fmt"
import "core:net"
import "core:strings"
import "core:bytes"
import "core:thread"
import "core:sync"
import "core:math/linalg"
import "vendor:raylib"

drawable_t :: struct {
    sprite : raylib.Texture2D,
    transform : transform_t
}

player_t :: struct {
    using drawable: drawable_t,
    test: f32
}

transform_t :: struct #align(4) {
    position : linalg.Vector3f32,
    rotation : f32,
    scale : f32,
}

command_type_t :: enum u16 {
    heartbeat = 11,
    update_data = 12,
    end_msg = 13,
    exit = 14,
}

types_t :: enum u16 {
    none,
    transform_data
}

update_component_command :: struct #align(4) {
    type: command_type_t,
}

parse_state_t :: enum {
    wait_for_command,
    parse_command_type,
    select_command,
    parse_data_type,
    parse_data,
    data_parse_end,
}

parse_info_t :: struct {
    package_byte_index: int,
    parse_byte_index: int,
    state: parse_state_t,
    type_to_parse: types_t,
    current_command: command_type_t
}

worker_data_t :: struct {
    out_socket: net.TCP_Socket,
    wait_group_data: ^sync.Wait_Group
}

sync_transform_data :: proc(target_socket: net.TCP_Socket, transform: transform_t) {

    buffer         := bytes.Buffer {}
    transform_data := transform
    command_type   := command_type_t.update_data
    data_type      := types_t.transform_data
    message_end    := command_type_t.end_msg

    bytes.buffer_write_ptr(&buffer, &command_type,   size_of(command_type))
    bytes.buffer_write_ptr(&buffer, &data_type,      size_of(types_t))
    bytes.buffer_write_ptr(&buffer, &transform_data, size_of(transform_t))
    bytes.buffer_write_ptr(&buffer, &message_end,    size_of(command_type))
    
    fmt.printf("Message size: %i\n", len(buffer.buf))

    buffer_slice: []u8 = buffer.buf[:len(buffer.buf)]
    net.send_tcp(target_socket, buffer_slice)
}

send_heartbeat :: proc(target_socket: net.TCP_Socket) {
    fmt.println("Sending heartbeat\n")
    buffer         := bytes.Buffer {}
    command_type   := command_type_t.heartbeat
    message_end    := command_type_t.end_msg

    bytes.buffer_write_ptr(&buffer, &command_type,   size_of(command_type))
    bytes.buffer_write_ptr(&buffer, &message_end,    size_of(command_type))
    fmt.printf("Message size: %i\n", len(buffer.buf))

    buffer_slice: []u8 = buffer.buf[:len(buffer.buf)]
    net.send_tcp(target_socket, buffer_slice)
}

draw_drawable :: proc (drawable: ^drawable_t) {
    using linalg

    dimensions := [2]f32{ 
        f32(drawable.sprite.width)  * drawable.transform.scale, 
        f32(drawable.sprite.height) * drawable.transform.scale 
    }

    texture_src := raylib.Rectangle{
        0, 0, 
        f32(drawable.sprite.width), 
        f32(drawable.sprite.height)
    }

    texture_dst := raylib.Rectangle{
        drawable.transform.position.x, 
        drawable.transform.position.y, 
        dimensions[0], 
        dimensions[1]
    }
    
    raylib.DrawTexturePro(
        drawable.sprite, 
        texture_src, 
        texture_dst, 
        dimensions / 2, drawable.transform.rotation, 
        raylib.WHITE)
}

cpy_pck_to_buffer :: proc(parse_buffer: ^bytes.Buffer, data_ptr: rawptr, parser_info: ^parse_info_t, size_of_type: int) -> bool {
    if parser_info.parse_byte_index < size_of_type {
        bytes_left_to_copy := size_of_type - parser_info.parse_byte_index
        bytes_budget := (package_size - parser_info.package_byte_index)

        bytes_to_copy := bytes_budget
        if bytes_budget >= bytes_left_to_copy {
            bytes_to_copy = bytes_left_to_copy   
        }

        bytes.buffer_write_ptr(parse_buffer, data_ptr, bytes_to_copy)
        parser_info.parse_byte_index += bytes_to_copy
        parser_info.package_byte_index += bytes_to_copy

        return parser_info.parse_byte_index == size_of_type
    }

    return true
}


handle_tcp_msg :: proc(socket: net.TCP_Socket, drawables: [dynamic] drawable_t) {
    parser_info:= parse_info_t {
        package_byte_index = 0,
        parse_byte_index = 0,
        state = parse_state_t.wait_for_command,
        type_to_parse = types_t.none
    }

    parse_buffer := bytes.Buffer {}
    data_in_bytes: [package_size]byte

    fmt.println("Wait for messages")
    _ ,err := net.recv_tcp(socket, data_in_bytes[:])

    if err != nil {
        fmt.panicf("error while recieving data: %s", err)
    }

    for parser_info.package_byte_index < package_size {
        #partial switch parser_info.state {
            case .wait_for_command: {
                // Check if command type fits package
                if (size_of(command_type_t) + parser_info.package_byte_index >= package_size) {
                    bytes.buffer_reset(&parse_buffer)
                    parser_info.parse_byte_index = 0

                    break
                }

                parser_info.state = parse_state_t.parse_command_type    
            }
            case .parse_command_type: {
                data_ptr := (rawptr)(&data_in_bytes[parser_info.package_byte_index])
                if cpy_pck_to_buffer(&parse_buffer, data_ptr, &parser_info, size_of(command_type_t)) {
                    fmt.println("Parsed command_type_t")
                    parser_info.current_command = (^command_type_t)(&parse_buffer.buf[0])^
                    parser_info.state = parse_state_t.select_command
                    bytes.buffer_reset(&parse_buffer)
                    parser_info.parse_byte_index = 0 
                }
            }
            case .select_command: {
                switch parser_info.current_command {
                    case .update_data: {
                        fmt.println("Update Command!")
                        parser_info.state = parse_state_t.parse_data_type
                    }
                    case .end_msg: {
                        fmt.println("End message Command")
                        parser_info.state = parse_state_t.data_parse_end
                    }
                    case .exit: {
                        fmt.println("Exit Command")
                    }
                    case .heartbeat: {
                        fmt.println("Received heartbeat")
                        parser_info.state = parse_state_t.wait_for_command
                    }
                    case: {
                        fmt.panicf("Unexpected command: %s", parser_info.current_command)
                    }
                }
            }
            case .parse_data_type: {
                data_ptr := (rawptr)(&data_in_bytes[parser_info.package_byte_index])
                if cpy_pck_to_buffer(&parse_buffer, data_ptr, &parser_info, size_of(types_t)) {
                    fmt.println("Parsed types_t")
                    parser_info.type_to_parse = (^types_t)(&parse_buffer.buf[0])^

                    bytes.buffer_reset(&parse_buffer)
                    parser_info.parse_byte_index = 0
                    parser_info.state = parse_state_t.parse_data
                }
            }
            case .parse_data: {
                data_ptr := (rawptr)(&data_in_bytes[parser_info.package_byte_index])
                #partial switch parser_info.type_to_parse {
                    case .transform_data: {
                        fmt.println("Parsing transform data")
                        if cpy_pck_to_buffer(&parse_buffer, data_ptr, &parser_info, size_of(transform_t)) {
                            data := (^transform_t)(&parse_buffer.buf[0])^
                            fmt.printf("Data received:\n", data)
                            fmt.printf("\n")
                            parser_info.state = parse_state_t.wait_for_command
                            drawables[0].transform = data
                            bytes.buffer_reset(&parse_buffer)
                            parser_info.parse_byte_index = 0
                        }
                    }
                }
            }
            case .data_parse_end: {
                fmt.println("Message Done")
                parser_info.package_byte_index = package_size
                break;
            }
        }
    }
}

get_communication_socket :: proc() -> net.TCP_Socket{
    socket_endpoint:= net.Endpoint{
        port = 1239,
        address = net.IP4_Loopback
    }

    socket: net.TCP_Socket

    when IS_SERVER
    {
        listen_socket, listen_err := net.listen_tcp(socket_endpoint)
        if listen_err != nil {
            fmt.panicf("listen error : %s", listen_err)
        }

        client_socket, client_endpoint, accept_err := net.accept_tcp(listen_socket)
        fmt.println("Accept connection")

        if accept_err != nil {
            fmt.panicf("%s",accept_err)
        }

        socket = client_socket
    }
    else 
    {
        for {

            host_socket, connect_err := net.dial_tcp_from_endpoint(socket_endpoint)
            if connect_err != nil {
                fmt.panicf("Connect error: %s",connect_err)
            }

            if (host_socket == 0) {
                continue
            }
    
            socket = host_socket
            fmt.println("Connected")
            fmt.printf("%i", host_socket)

            break;
        }

    }

    return socket
}

get_communication_socket_worker :: proc(t: ^thread.Thread) {
    fmt.printf("work of thread  %d started \n", t.user_index)

    socket := get_communication_socket()

    // getting values that we passed while initilizing our thread
    dereferenced_value := (cast(^worker_data_t)t.data)
    dereferenced_value.out_socket = socket

    fmt.println("work of thread %d done", t.user_index)
    // this function just does counter--
    // which tells that our function has done its work
    sync.wait_group_done(dereferenced_value.wait_group_data)
}


main :: proc() {
    using linalg

    screen_size :: [2]i32 { 800, 600 }

    raylib.InitWindow(screen_size[0], screen_size[1],  "Server" when IS_SERVER else "Client")
    raylib.SetTargetFPS(60)

    // Setup thread for async client/server connection waiting
    wg : sync.Wait_Group
    get_socket_thread := thread.create(get_communication_socket_worker)
    get_socket_thread.init_context = context 
    get_socket_thread.user_index = 1
    get_socket_thread.data = &worker_data_t { 
        out_socket = {},
        wait_group_data = &wg
    }
    sync.wait_group_add(&wg, 1)
    thread.start(get_socket_thread)

    // Communicate to user that we're looking for client/server
    for !raylib.WindowShouldClose() && wg.counter != 0 {
        raylib.BeginDrawing()
        raylib.ClearBackground(raylib.Color{0,0,0,0})
        raylib.DrawText("Waiting for Client connection" when IS_SERVER else "Waiting for Server connection", 10, 10, 20, raylib.LIGHTGRAY);
        raylib.EndDrawing()
    }

    // Retrieve found connection from thread
    socket := (cast(^worker_data_t)get_socket_thread.data).out_socket

    // Setup our player
    player := player_t {
        sprite   = raylib.LoadTexture("assets/textures/player/player_01.png"),
        transform = transform_t{
            position = Vector3f32{100, 100, 0},
            rotation = 0,
            scale    = 3,
        }
    }
 
    drawables:= [dynamic] drawable_t {}
    append(&drawables, player)

    for !raylib.WindowShouldClose() {
        // Server sided code
        when IS_SERVER {
            for &drawable in drawables {
                drawable.transform.rotation += 1
            }
            
            // Server is able to control player
            if raylib.IsKeyDown(.D) { drawables[0].transform.position.x += 2.0; }
            if raylib.IsKeyDown(.A) { drawables[0].transform.position.x -= 2.0; }
            if raylib.IsKeyDown(.W) { drawables[0].transform.position.y -= 2.0; }
            if raylib.IsKeyDown(.S) { drawables[0].transform.position.y += 2.0; }

            // Sync the transform data to our connected client
            sync_transform_data(socket, drawables[0].transform)
        } 
        else { // Client sided code
            // Generic heartbeat
            send_heartbeat(socket)
        }

        // Shared code space
        {
            handle_tcp_msg(socket, drawables)

            raylib.BeginDrawing()
            raylib.ClearBackground(raylib.Color{0,0,0,0})
    
            for &drawable in drawables {
                draw_drawable(&drawable)
            }

            raylib.DrawText("Connected!", 10, 10, 20, raylib.LIGHTGRAY);
            raylib.EndDrawing()
        }
    }
}