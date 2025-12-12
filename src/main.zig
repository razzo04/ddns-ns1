const std = @import("std");
const http = std.http;
const json = std.json;
const mem = std.mem;
const os = std.os;

const log = std.log.scoped(.ddns_ns1);

const Client = std.http.Client;

const Config = struct {
    ns1_api_key: []const u8,
    zone: []const u8,
    base_domain: []const u8,
};

fn getConfig(allocator: mem.Allocator) !Config {
    var env_map = try std.process.getEnvMap(allocator);

    const ns1_api_key = env_map.get("NS1_API_KEY") orelse return error.MissingNs1ApiKey;
    const zone = env_map.get("ZONE") orelse return error.MissingZone;
    const base_domain = env_map.get("BASE_DOMAIN") orelse return error.MissingBaseDomain;

    return Config{
        .ns1_api_key = ns1_api_key,
        .zone = zone,
        .base_domain = base_domain,
    };
}

fn getPublicIp(allocator: mem.Allocator) ![]u8 {
    log.info("Fetching public IP...", .{});

    var allocating = std.Io.Writer.Allocating.init(allocator);

    const opts: Client.FetchOptions = .{
        .method = .GET,
        .location = .{ .url = "https://api.ipify.org" },
        .response_writer = &allocating.writer,
    };

    var client: Client = .{ .allocator = allocator };
    defer client.deinit();

    const res = try client.fetch(opts);

    if (res.status != .ok) {
        log.err("Failed to fetch public IP, status {any}", .{res.status});
        return error.FailedToFetchPublicIp;
    }

    log.info("Public IP: {s}", .{allocating.written()});
    return allocating.written();
}

fn updateNs1Record(allocator: std.mem.Allocator, config: Config, ip: []const u8) !void {
    const domain = try std.fmt.allocPrint(allocator, "*.{s}", .{config.base_domain});
    defer allocator.free(domain);

    log.info("Updating NS1 record for {s}...", .{domain});

    // 1. Prepare strings
    const uri_string = try std.fmt.allocPrint(allocator, "https://api.nsone.net/v1/zones/{s}/{s}/A", .{ config.zone, domain });
    defer allocator.free(uri_string);

    const payload_string = try std.fmt.allocPrint(allocator, "{{" ++
        "\"zone\":\"{s}\"," ++
        "\"domain\":\"{s}\"," ++
        "\"type\":\"A\"," ++
        "\"answers\":[{{\"answer\":[\"{s}\"]}}]" ++
        "}}", .{ config.zone, domain, ip });
    defer allocator.free(payload_string);

    // 2. Setup Client
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // 3. Define Headers (using a slice of structs)
    const headers = &[_]std.http.Header{
        .{ .name = "X-NSONE-Key", .value = config.ns1_api_key },
        .{ .name = "Content-Type", .value = "application/json" },
    };

    // 4. Setup Response Storage (Standard replacement for Allocating Writer)
    var response_body = std.Io.Writer.Allocating.init(allocator);
    defer response_body.deinit();

    // 5. Execute Fetch
    const result = try client.fetch(.{
        .location = .{ .url = uri_string },
        .method = .POST,
        .extra_headers = headers, // Replaces std.http.Headers
        .payload = payload_string,
        .response_writer = &response_body.writer, // Stores response in the ArrayList
    });

    // 6. Handle "Not Found" by trying to Create
    if (result.status == .not_found) {
        log.info("Record does not exist (404). Attempting to CREATE (PUT)...", .{});

        // Reset the response buffer for the next request
        response_body.clearRetainingCapacity();

        // Attempt 2: PUT (Create)
        const create_res = try client.fetch(.{
            .location = .{ .url = uri_string },
            .method = .PUT, // Change method to PUT
            .extra_headers = headers,
            .payload = payload_string,
            .response_writer = &response_body.writer,
        });

        if (create_res.status == .ok) {
            log.info("Successfully created NS1 record.", .{});
            return;
        } else {
            log.err("Failed to create NS1 record, status: {any}", .{create_res.status});
            log.err("Response body: {s}", .{response_body.written()});
            return error.FailedToCreateNs1Record;
        }
    } else if (result.status == .ok) {
        log.info("Successfully update NS1 record.", .{});
        return;
    }

    // 7. Handle other errors
    log.err("Failed to update NS1 record, status: {any}", .{result.status});
    log.err("Response body: {s}", .{response_body.written()});
    return error.FailedToUpdateNs1Record;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.log.info("Starting DDNS NS1 updater.", .{});

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arenaAllocator = arena.allocator();

    const config = try getConfig(arenaAllocator);
    const ip = try getPublicIp(arenaAllocator);

    try updateNs1Record(arenaAllocator, config, ip);
}
