//
//  FloorPlanTemplateTests.swift
//  A Seat AwaitsTests
//
//  Guards the template JSON shape (tables_json / rooms_json) so layouts authored
//  on the web's `useFloorplanTemplates` round-trip cleanly on iOS, and the legacy
//  single-room decode path keeps working.
//

import Foundation
import Testing
@testable import A_Seat_Awaits

@Test func templateTableUsesSnakeCaseKeys() throws {
    let table = TemplateTable(name: "Head", shape: "rectangle", capacity: 8,
                              width: 240, height: 120, positionX: 100, positionY: 200,
                              rotation: 90, description: "VIP", isCustom: true)
    let data = try JSONEncoder().encode(table)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["position_x"] as? Double == 100)
    #expect(json["position_y"] as? Double == 200)
    #expect(json["is_custom"] as? Bool == true)
    #expect(json["shape"] as? String == "rectangle")
    #expect(json["capacity"] as? Int == 8)
}

@Test func templateDecodesWebShape() throws {
    // A row shaped exactly like the web app writes it.
    let raw = """
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "user_id": "22222222-2222-2222-2222-222222222222",
      "name": "Garden party",
      "room_width_ft": 50,
      "room_height_ft": 80,
      "tables_json": [
        {"name":"Table 1","shape":"circle","capacity":10,"width":120,"height":120,
         "position_x":48,"position_y":48,"rotation":0,"description":null,"is_custom":false}
      ],
      "rooms_json": [
        {"name":"Hall","width_ft":40,"height_ft":30,"position_x":0,"position_y":0,
         "color":"#E5E7EB","sort_order":0}
      ]
    }
    """.data(using: .utf8)!

    let template = try JSONDecoder().decode(FloorPlanTemplate.self, from: raw)
    #expect(template.name == "Garden party")
    #expect(template.tablesJson.count == 1)
    #expect(template.tablesJson[0].tableShape == .circle)
    #expect(template.tablesJson[0].capacity == 10)
    #expect(template.roomsJson.count == 1)
    #expect(template.roomsJson[0].widthFt == 40)
    #expect(template.roomsJson[0].sortOrder == 0)
    #expect(template.totalSeats == 10)
    #expect(template.summary == "1 table · 1 room")
}

@Test func templateToleratesMissingArraysAndFields() throws {
    // Minimal row: no tables_json/rooms_json, sparse table fields.
    let raw = """
    {
      "id":"a","user_id":"b","name":"Bare",
      "tables_json":[{"name":"T","shape":"square","capacity":4}]
    }
    """.data(using: .utf8)!
    let template = try JSONDecoder().decode(FloorPlanTemplate.self, from: raw)
    #expect(template.roomsJson.isEmpty)
    #expect(template.tablesJson[0].width == 120)   // default
    #expect(template.tablesJson[0].rotation == 0)  // default
    #expect(template.summary == "1 table")
}
