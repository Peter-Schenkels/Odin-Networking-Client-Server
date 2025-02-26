#+feature dynamic-literals

package main
IS_SERVER :: #config(IS_SERVER, false)
package_size :: 1024
prediciton_snapshots :: 560

import "core:fmt"
import "core:net"
import "core:strings"
import "core:bytes"
import "core:slice"
import "base:intrinsics"
import "core:thread"
import "core:sync"
import "core:time"
import "core:math/linalg"
import "core:hash"
import "vendor:raylib"

drawable_t :: struct {
    sprite : raylib.Texture2D,
    transform : transform_t
}

transform_t :: struct #align(4) {
    position : linalg.Vector3f32,
    rotation : f32,
    scale : f32,
}

player_t :: struct {
    using drawable: drawable_t,
    input: input_data_t,
    id: int,
}

command_type_t :: enum u16 {
    end_msg = 0,
    heartbeat = 11,
    update_data = 12,
    exit = 14,
    create_data = 15,
    create_entity = 16,
    raise_flag = 17,
    lower_flag = 18,
    create_event = 19,
    assign_player,
}

types_t :: enum u16 {
    none,
    transform_data,
    input_data,
    player_info,
    event,
}

parse_state_t :: enum {
    wait_for_command,
    parse_command_type,
    select_command,
    parse_data_type,
    parse_data_entity_id,
    parse_data,
    data_parse_end,
    assign_player,
}

parse_info_t :: struct {
    package_byte_index: int,
    parse_byte_index: int,
    state: parse_state_t,
    type_to_parse: types_t,
    current_command: command_type_t,
    entity_id: int
}

get_socket_worker_data_t :: struct {
    out_socket: net.TCP_Socket,
    wait_group_data: ^sync.Wait_Group
}


mutex_game_data_t :: struct {
    mutex: sync.RW_Mutex,
    ptr: ^game_context_t
}   

game_thread_worker_data_t :: struct {
    wait_group_data: ^sync.Wait_Group,
    game_data: mutex_game_data_t,
    net_context: ^networking_context_t
}


event_types_t :: enum {
    start_match,
    create_player
}

event_t :: struct {
    type: event_types_t,
    target_id: int
}

flag_types_t :: enum {
    pre_game,
    match
}

flag_t :: struct {
    type: flag_types_t,
}

ready_t :: enum {
    wait_for_ready,
    is_ready,
    failed,
}

player_info_t :: struct {
    socket: net.TCP_Socket,
    id: int,
    ready: ready_t,
}

multiplayer_game_t :: struct {
    local_player: player_info_t
}

game_context_t :: struct {
    players: [dynamic]player_t,
    events:  [dynamic]event_t,
    flags:   [dynamic]flag_t,
    current_tick: u64,
    delta_time: f64,
    prev_tick_duration: f64,
    prev_tick: time.Tick,

    multiplayer: multiplayer_game_t,
    assets: asset_context_t,
    predictions: prediction_context_t
}

asset_context_t :: struct {
    player_sprite_sheet : raylib.Texture2D
}

networking_context_t :: struct {
    recv_cmd_buffer: bytes.Buffer, 
    send_cmd_buffer: bytes.Buffer, 
    socket: net.TCP_Socket,
    index: int,
    new_message: bool,
    recv_buffer_mutex: ^sync.RW_Mutex,
    send_buffer_mutex: ^sync.RW_Mutex,
    sent_heartbeat: bool
}

input_data_t :: struct {
    direction : linalg.Vector2f32,
}

prediction_state_t :: struct {
    tick : u64,
    hash : u64
}

player_prediction_state_t :: struct {
   snapshots : [prediciton_snapshots]prediction_state_t,
   snapshot_index : i32,
}

prediction_context_t :: struct {
    player_snapshots : [2]player_prediction_state_t
}


decrease_float_precision :: proc(a: f32, bits_lost: u32) -> f32 {
    return transmute(f32)((transmute(u32)a) >> bits_lost)
}

get_transform_data_error_margin_hash :: proc(transform: ^transform_t) -> u64 {
    approx_transform := transform^
    precision_lost : u32 = 23

    approx_transform.position.x = decrease_float_precision(approx_transform.position.x, precision_lost)
    approx_transform.position.y = decrease_float_precision(approx_transform.position.y, precision_lost)
    approx_transform.position.z = decrease_float_precision(approx_transform.position.z, precision_lost)

    return get_data_hash(&approx_transform, size_of(transform_t))
}


should_reconciliate_player :: proc(target_player : int, game_context: ^game_context_t, received_data_hash: u64) -> bool {
    for &snapshot in game_context.predictions.player_snapshots[target_player].snapshots {
        if snapshot.hash == received_data_hash {
            //fmt.println("Prediction Hit")
            return false
        }
    }

    //fmt.println("Predition Miss")
    return true
}

get_data_hash :: proc(ptr: rawptr, data_size: int) -> u64 {
    data := slice.bytes_from_ptr(ptr, data_size)
    return hash.crc64_ecma_182(data)
}

add_player_snapshot :: proc(target_player: ^player_t, state : ^player_prediction_state_t, current_tick : u64) {
    if (state.snapshot_index == prediciton_snapshots) {
        intrinsics.mem_copy(&state.snapshots[0], &state.snapshots[1], prediciton_snapshots - 1)
        state.snapshot_index -= 1
    }

    state.snapshots[state.snapshot_index] = prediction_state_t {
        tick = current_tick,
        hash = get_transform_data_error_margin_hash(&target_player.transform)
    }

    state.snapshot_index += 1
}

register_predicted_tick :: proc(game_context: ^game_context_t) {
    for &player in game_context.players {
        add_player_snapshot(&player, &game_context.predictions.player_snapshots[player.id], game_context.current_tick)
    }
}

event_system_tick :: proc(game_context: ^game_context_t) {
    for &event in game_context.events {
        switch event.type {
            case .start_match: {

            }
            case .create_player: {
                fmt.printfln("Creating player: %i", event.target_id)
                create_player_entity(game_context, event.target_id, linalg.Vector3f32{0,0,0})
            }
        }
    }

    clear(&game_context.events)
}

input_system_tick :: proc(game_context: ^game_context_t) {
    index := 0
    for &player in game_context.players{
        if game_context.multiplayer.local_player.id == index {
            player.input.direction = {}

            if raylib.IsKeyDown(.D) { player.input.direction.x += 1.0 }
            if raylib.IsKeyDown(.A) { player.input.direction.x -= 1.0 }
            if raylib.IsKeyDown(.W) { player.input.direction.y -= 1.0; }
            if raylib.IsKeyDown(.S) { player.input.direction.y += 1.0; }

            if (player.input.direction.x != 0 || player.input.direction.y != 0)
            {
                player.input.direction = linalg.vector_normalize(player.input.direction)
            }
        }

        speed : f32 = 300
        player.transform.position += { player.input.direction.x, player.input.direction.y, 0 } * f32(game_context.delta_time) * speed

        index += 1
    }
}


sync_create_player_entity :: proc (entity_id: int, position: linalg.Vector3f32, net_context: ^networking_context_t) {
    entity_id := entity_id
    create_player_event := event_t {
        type = event_types_t.create_player,
        target_id = entity_id
    }
    event_data_type:= types_t.event
    player_transform: transform_t
    player_transform.position = position
    transform_type:= types_t.transform_data

    when IS_SERVER {
        sync_entity_data(net_context, &create_player_event, size_of(event_t), event_data_type, entity_id)
    }
}

create_player_entity :: proc (game_context: ^game_context_t, entity_id: int, position: linalg.Vector3f32) {
    player := player_t {
        sprite   = game_context.assets.player_sprite_sheet,
        transform = transform_t{
            position = position,
            rotation = 0,
            scale    = 3,
        },
        id = entity_id,
    }

    inject_at(&game_context.players, entity_id, player)
}

sync_assign_player :: proc(player_info: ^player_info_t, net_context: ^networking_context_t) {
    buffer         := &net_context.send_cmd_buffer
    command_type   := command_type_t.assign_player
    message_end    := command_type_t.end_msg
    data_type      := types_t.player_info

    sync.lock(net_context.send_buffer_mutex)
    {
        bytes.buffer_write_ptr(buffer, &command_type,   size_of(command_type))
        bytes.buffer_write_ptr(buffer, player_info,     size_of(player_info_t))
        bytes.buffer_write_ptr(buffer, &message_end,    size_of(command_type))
    }
    sync.unlock(net_context.send_buffer_mutex)

    //fmt.printf("Message size: %i\n", len(buffer.buf))
}

sync_entity_data :: proc(net_context: ^networking_context_t, data: rawptr, size_of_data: int, data_type: types_t, entity_id: int) {
    buffer         := &net_context.send_cmd_buffer
    command_type   := command_type_t.update_data
    message_end    := command_type_t.end_msg
    entity_id      := entity_id
    data_type      := data_type

    sync.lock(net_context.send_buffer_mutex)
    {
        for i:=0; i < 2; i += 1 {
            bytes.buffer_write_ptr(buffer, &command_type,   size_of(command_type))
            bytes.buffer_write_ptr(buffer, &entity_id,      size_of(int))
            bytes.buffer_write_ptr(buffer, &data_type,      size_of(types_t))
            bytes.buffer_write_ptr(buffer, data,            size_of_data)
            bytes.buffer_write_ptr(buffer, &message_end,    size_of(command_type))
    
            // Send same message to receive buffer
            buffer = &net_context.recv_cmd_buffer
        }
    }
    sync.unlock(net_context.send_buffer_mutex)

    //fmt.printf("Message size: %i\n", len(buffer.buf))
}

send_heartbeat :: proc(net_context: ^networking_context_t) {
    //fmt.println("Sending heartbeat\n")
    buffer         := &net_context.send_cmd_buffer
    command_type   := command_type_t.heartbeat
    message_end    := command_type_t.end_msg

    sync.lock(net_context.send_buffer_mutex)
    {
        bytes.buffer_write_ptr(buffer, &command_type,   size_of(command_type))
        bytes.buffer_write_ptr(buffer, &message_end,    size_of(command_type))
    }
    sync.unlock(net_context.send_buffer_mutex)

    //fmt.printf("Message size: %i\n", len(buffer.buf))
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

parse_net_buffer :: proc (game_context: ^game_context_t, net_context: ^networking_context_t)
{
    data_in_bytes: []byte
    if (!net_context.new_message)
    {
        return
    }

    if sync.try_lock(net_context.recv_buffer_mutex) {
        data_in_bytes = net_context.recv_cmd_buffer.buf[:]
        bytes.buffer_reset(&net_context.recv_cmd_buffer)
        net_context.new_message = false
        sync.unlock(net_context.recv_buffer_mutex)
    }
    else {
        return
    }

    //fmt.println(data_in_bytes)

    parse_buffer := bytes.Buffer {}
    parser_info:= parse_info_t {
        package_byte_index = 0,
        parse_byte_index = 0,
        state = parse_state_t.wait_for_command,
        type_to_parse = types_t.none
    }

    for parser_info.package_byte_index < len(data_in_bytes) {
        //fmt.eprintfln("Byte index %i - data_len: %i", parser_info.package_byte_index, len(data_in_bytes))
        parsing_finished := false;
        switch parser_info.state {
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
                    //fmt.println("Parsed command_type_t")
                    parser_info.current_command = (^command_type_t)(&parse_buffer.buf[0])^

                    parser_info.state = parse_state_t.select_command
                    bytes.buffer_reset(&parse_buffer)
                    parser_info.parse_byte_index = 0 
                }
                else {
                    fmt.panicf("Corrupted message buffer")
                }
            }
            case .select_command: {
                #partial switch parser_info.current_command {
                    case .update_data: {
                        //fmt.println("Update Command!")
                        parser_info.state = parse_state_t.parse_data_entity_id
                    }
                    case .end_msg: {
                        //fmt.println("End message Command")
                        parser_info.state = parse_state_t.data_parse_end
                    }
                    case .exit: {
                        //fmt.println("Exit Command")
                    }
                    case .heartbeat: {
                        //fmt.println("Received heartbeat")
                        parser_info.state = parse_state_t.wait_for_command
                    }
                    case .assign_player: {
                        //fmt.println("Assigning local player")
                        parser_info.state = parse_state_t.assign_player
                    }
                    case: {
                        fmt.panicf("Unexpected command: %s", parser_info.current_command)
                    }
                }
            }
            case .assign_player: {
                data_ptr := (rawptr)(&data_in_bytes[parser_info.package_byte_index])
                if cpy_pck_to_buffer(&parse_buffer, data_ptr, &parser_info, size_of(player_info_t)) {
                    game_context.multiplayer.local_player = (^player_info_t)(&parse_buffer.buf[0])^

                    bytes.buffer_reset(&parse_buffer)
                    parser_info.parse_byte_index = 0
                    parser_info.state = parse_state_t.wait_for_command
                }
                else {
                    fmt.panicf("Corrupted message buffer")
                }
            }
            case .parse_data_entity_id: {
                data_ptr := (rawptr)(&data_in_bytes[parser_info.package_byte_index])
                if cpy_pck_to_buffer(&parse_buffer, data_ptr, &parser_info, size_of(int)) {
                    parser_info.entity_id = (^int)(&parse_buffer.buf[0])^

                    bytes.buffer_reset(&parse_buffer)
                    parser_info.parse_byte_index = 0
                    parser_info.state = parse_state_t.parse_data_type
                }
                else {
                    fmt.panicf("Corrupted message buffer")
                }
            }
            case .parse_data_type: {
                data_ptr := (rawptr)(&data_in_bytes[parser_info.package_byte_index])
                if cpy_pck_to_buffer(&parse_buffer, data_ptr, &parser_info, size_of(types_t)) {
                    //fmt.println("Parsed types_t")
                    parser_info.type_to_parse = (^types_t)(&parse_buffer.buf[0])^

                    bytes.buffer_reset(&parse_buffer)
                    parser_info.parse_byte_index = 0
                    parser_info.state = parse_state_t.parse_data
                }
                else {
                    fmt.panicf("Corrupted message buffer")
                }
            }
            case .parse_data: {
                data_ptr := (rawptr)(&data_in_bytes[parser_info.package_byte_index])
                parsing_finished := false;

                #partial switch parser_info.type_to_parse {
                    case .transform_data: {
                        if cpy_pck_to_buffer(&parse_buffer, data_ptr, &parser_info, size_of(transform_t)) {
                            data := (^transform_t)(&parse_buffer.buf[0])^
                            
                            when !IS_SERVER {
                                received_state := get_transform_data_error_margin_hash(&data)

                                if (should_reconciliate_player(parser_info.entity_id, game_context, received_state))
                                {
                                    game_context.players[parser_info.entity_id].transform = data
                                }
                            }

                            bytes.buffer_reset(&parse_buffer)
                            parser_info.parse_byte_index = 0
                            parser_info.state = parse_state_t.wait_for_command
                        }
                        else {
                            fmt.panicf("Corrupted message buffer")
                        }
                    }
                    case .input_data: {
                        if cpy_pck_to_buffer(&parse_buffer, data_ptr, &parser_info, size_of(input_data_t)) {
                            data := (^input_data_t)(&parse_buffer.buf[0])^
                            game_context.players[parser_info.entity_id].input = data

                            bytes.buffer_reset(&parse_buffer)
                            parser_info.parse_byte_index = 0
                            parser_info.state = parse_state_t.wait_for_command
                        }
                        else {
                            fmt.panicf("Corrupted message buffer")
                        }
                    }
                    case .event: {
                        if cpy_pck_to_buffer(&parse_buffer, data_ptr, &parser_info, size_of(event_t)) {
                            data := (^event_t)(&parse_buffer.buf[0])^
                            append(&game_context.events, data)
                            fmt.println("Event create")    
                            bytes.buffer_reset(&parse_buffer)
                            parser_info.parse_byte_index = 0
                            parser_info.state = parse_state_t.wait_for_command

                            event_system_tick(game_context)
                        }
                        else {
                            fmt.panicf("Corrupted message buffer")
                        }
                    }
                }
            }
            case .data_parse_end: {
                //fmt.println("Message Done")
                parser_info.state = parse_state_t.wait_for_command
                break;
            }
        }
    }
}


handle_tcp_msg :: proc(game_context: ^game_context_t, net_context: ^networking_context_t) {
    data_in_bytes: [package_size]byte

    if net_context.sent_heartbeat  {
        byte_count ,err := net.recv_tcp(net_context.socket, data_in_bytes[:])
    
        if (byte_count > 0)
        {
            sync.lock(net_context.recv_buffer_mutex)
            {
                bytes.buffer_write_ptr(&net_context.recv_cmd_buffer, &data_in_bytes, byte_count)
                net_context.new_message = true
                net_context.sent_heartbeat = false
            }
            sync.unlock(net_context.recv_buffer_mutex)
        }
    
        if err != nil {
            fmt.panicf("error while recieving data: %s", err)
        }
    }
    else {
        if len(net_context.send_cmd_buffer.buf) == 0 {
            send_heartbeat(net_context)
        }

        sync.lock(net_context.send_buffer_mutex)
        data_buffer := net_context.send_cmd_buffer.buf[:len(net_context.send_cmd_buffer.buf)]
        bytes.buffer_reset(&net_context.send_cmd_buffer)
        sync.unlock(net_context.send_buffer_mutex)
        
        net.send_tcp(net_context.socket, data_buffer)
        net_context.sent_heartbeat = true
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

            break;
        }
    }

    return socket
}

get_communication_socket_worker :: proc(t: ^thread.Thread) {
    fmt.printf("work of thread  %d started \n", t.user_index)
    socket := get_communication_socket()

    dereferenced_value := (cast(^get_socket_worker_data_t)t.data)
    dereferenced_value.out_socket = socket

    fmt.printfln("work of thread %d done", t.user_index)
    sync.wait_group_done(dereferenced_value.wait_group_data)
}


game_thread_worker :: proc(t: ^thread.Thread) {
    using linalg

    worker_data := (cast(^game_thread_worker_data_t)t.data)
    game_context : ^game_context_t = worker_data.game_data.ptr
    net_context  : ^networking_context_t = worker_data.net_context

    when IS_SERVER {
        entity_id_counter := 0
        game_context.multiplayer.local_player.id = entity_id_counter
        entity_id_counter += 1

        other_player_info := player_info_t {
            socket = net_context.socket,
            id     = entity_id_counter,
            ready  = ready_t.wait_for_ready,
        }

        entity_id_counter += 1

        sync_assign_player(&other_player_info, net_context)
        sync_create_player_entity(game_context.multiplayer.local_player.id, Vector3f32{200,200,0}, net_context)
        sync_create_player_entity(other_player_info.id, Vector3f32{0,0,0}, net_context)

        parse_net_buffer(game_context, net_context)
        handle_tcp_msg(game_context, net_context) 
    }
    else {
        for game_context.multiplayer.local_player.id == 65536 {
            handle_tcp_msg(game_context, net_context)
            parse_net_buffer(game_context, net_context)
        }
    }

    for  {
        start_tick := time.tick_now()
        target_frame_duration := time.Second / 60

        sync.lock(&worker_data.game_data.mutex)
        {
            local_player_info := worker_data.game_data.ptr.multiplayer.local_player

            worker_data.game_data.ptr.delta_time = time.duration_seconds(time.tick_since(worker_data.game_data.ptr.prev_tick))

            input_system_tick(worker_data.game_data.ptr)

            for &player in worker_data.game_data.ptr.players {
                when IS_SERVER {
                    sync_entity_data(worker_data.net_context, rawptr(&player.transform), size_of(transform_t), types_t.transform_data, player.id)
                }
                
                if player.id == local_player_info.id {
                    sync_entity_data(worker_data.net_context, rawptr(&player.input), size_of(input_data_t), types_t.input_data, player.id)       
                }
            }
            
            parse_net_buffer(game_context, net_context)
            handle_tcp_msg(worker_data.game_data.ptr, worker_data.net_context)

            worker_data.game_data.ptr.prev_tick_duration = time.duration_seconds(time.tick_since(start_tick))
            worker_data.game_data.ptr.prev_tick          = start_tick

            when !IS_SERVER {
                register_predicted_tick(game_context)
            }
        }
        sync.unlock(&worker_data.game_data.mutex)
        duration := time.tick_since(start_tick)
        time.accurate_sleep(target_frame_duration - duration)
    }

    sync.wait_group_done(worker_data.wait_group_data)
}


main :: proc() {
    using linalg

    screen_size :: [2]i32 { 800, 600 }

    raylib.InitWindow(screen_size[0], screen_size[1],  "Server" when IS_SERVER else "Client")
    raylib.SetTargetFPS(60)

    when IS_SERVER {
        raylib.SetWindowPosition(800, 600)
    }

    // Game start
    game_context := game_context_t {}
    game_context.multiplayer.local_player.id = 65536
    game_context.assets.player_sprite_sheet = raylib.LoadTexture("assets/textures/player/player_01.png")

    // Setup thread for async client/server connection waiting
    wg_socket : sync.Wait_Group
    get_socket_thread := thread.create(get_communication_socket_worker)
    get_socket_thread.init_context = context 
    get_socket_thread.user_index = 1
    get_socket_thread.data = &get_socket_worker_data_t { 
        out_socket = {},
        wait_group_data = &wg_socket
    }
    sync.wait_group_add(&wg_socket, 1)
    thread.start(get_socket_thread)

    // Communicate to user that we're looking for client/server
    for !raylib.WindowShouldClose() && wg_socket.counter != 0 {
        raylib.BeginDrawing()
        raylib.ClearBackground(raylib.Color{0,0,0,0})
        raylib.DrawText("Waiting for Client connection" when IS_SERVER else "Waiting for Server connection", 10, 10, 20, raylib.LIGHTGRAY);
        raylib.EndDrawing()
    }

    // Retrieve found connection from thread
    socket := (cast(^get_socket_worker_data_t)get_socket_thread.data).out_socket
    net_context := networking_context_t {}
    net_context.socket = socket
    net_context.recv_buffer_mutex = &sync.RW_Mutex {}
    net_context.send_buffer_mutex = &sync.RW_Mutex {}

    // Setup render thread
    wg_render : sync.Wait_Group
    game_thread_worker_data := game_thread_worker_data_t { 
        wait_group_data = &wg_render,
        game_data = mutex_game_data_t{
            mutex = sync.RW_Mutex {},
            ptr = &game_context,
        },
        net_context = &net_context
    }

    render_thread := thread.create(game_thread_worker)
    render_thread.init_context = context 
    render_thread.user_index = 1
    render_thread.data = &game_thread_worker_data

    // Start rendering thread
    sync.wait_group_add(&wg_render, 1)
    thread.start(render_thread)


    when IS_SERVER {
        entity_id_counter := 0
        game_context.multiplayer.local_player.id = entity_id_counter
        entity_id_counter += 1
        other_player_info := player_info_t {
            socket = socket,
            id = entity_id_counter,
            ready = ready_t.wait_for_ready,
        }
        entity_id_counter += 1

        for !raylib.WindowShouldClose() {
            raylib.BeginDrawing()
            raylib.ClearBackground(raylib.Color{0,0,0,0})
            raylib.DrawText("Assigning players" when IS_SERVER else "Waiting for match to start", 10, 10, 20, raylib.LIGHTGRAY);
            raylib.EndDrawing()
            break
        }
    }
    else {
        for !raylib.WindowShouldClose() {
            raylib.BeginDrawing()
            raylib.ClearBackground(raylib.Color{0,0,0,0})
            raylib.DrawText("Assigning players" when IS_SERVER else "Waiting for match to start", 10, 10, 20, raylib.LIGHTGRAY);
            raylib.EndDrawing()
            if game_context.multiplayer.local_player.id != 65536 {
                break
            }
        }
    }

    for wg_render.counter > 0 && !raylib.WindowShouldClose() {
        start_tick := time.tick_now()

        raylib.BeginDrawing()
       // fmt.println("render tick")
        raylib.ClearBackground(raylib.Color{0,0,0,0})    
        sync.lock(&game_thread_worker_data.game_data.mutex)
        {
            for &player in game_context.players {
                draw_drawable(&player)
            }
        } 
        sync.unlock(&game_thread_worker_data.game_data.mutex)

        raylib.DrawText("Connected!", 10, 10, 20, raylib.LIGHTGRAY);
        raylib.EndDrawing()

        duration := time.tick_since(start_tick)

        formatted_duration := strings.clone_to_cstring(fmt.aprintf("Duration: %i", duration / time.Millisecond)) 
        raylib.DrawText(formatted_duration, 550, 10, 20, raylib.LIGHTGRAY);

        frame_duration := (time.Second / 60)
        time.accurate_sleep(frame_duration - duration)
    }
}