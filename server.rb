require "webrick"
require "json"
require "csv"
require "time"

require_relative "./scheduler"

PUBLIC_DIR = File.join(__dir__, "public")

def content_type_for(path)
  case File.extname(path)
  when ".html" then "text/html; charset=utf-8"
  when ".js" then "application/javascript; charset=utf-8"
  when ".css" then "text/css; charset=utf-8"
  when ".svg" then "image/svg+xml"
  when ".png" then "image/png"
  when ".jpg", ".jpeg" then "image/jpeg"
  else "application/octet-stream"
  end
end

def serve_static(path, res)
  safe = File.expand_path(path)
  public_root = File.expand_path(PUBLIC_DIR)
  return false unless safe.start_with?(public_root + File::SEPARATOR) || safe == public_root
  return false unless File.file?(safe)

  res.status = 200
  res["Content-Type"] = content_type_for(safe)
  res.body = File.binread(safe)
  true
end

def build_csv(schedule)
  teams = schedule["teams"]
  courts = schedule["courts"]
  include_ref = schedule["includeRef"]
  include_round_time = schedule["includeRoundTime"]

  ref_slot_labels = schedule["refSlotLabels"] || []
  ref_slot_labels = ref_slot_labels.sort_by { |x| x["slotIndex"] }

  headers = ["Round"]
  headers << "Time" if include_round_time

  courts.times do |ci|
    headers << "Court #{ci + 1}A"
    headers << "Court #{ci + 1}B"
  end

  if include_ref
    ref_slot_labels.each do |slot|
      headers << slot["label"]
    end
  end

  headers << "Bye"

  csv = CSV.generate(force_quotes: true) do |out|
    fmt_team = ->(team_idx0) { "{#{team_idx0 + 1}}" }
    out << headers

    rounds = schedule["rounds"]
    rounds.each_with_index do |round, ri|
      row = []
      row << (ri + 1)
      if include_round_time
        row << schedule["roundTimes"][ri]["start"]
      end

      games = round["games"]
      courts.times do |ci|
        game = games[ci]
        if game.nil?
          row << nil
          row << nil
        else
          t1, t2 = game
          row << fmt_team.call(t1)
          row << fmt_team.call(t2)
        end
      end

      if include_ref
        team_by_slotindex = {}
        round["refs"].each do |ref|
          team_by_slotindex[ref["slotIndex"]] = ref["team"]
        end
        ref_slot_labels.each do |slot|
          si = slot["slotIndex"]
          row << (team_by_slotindex.key?(si) ? fmt_team.call(team_by_slotindex[si]) : nil)
        end
      end

      byes = round["byes"].map { |t| fmt_team.call(t) }
      row << (byes.empty? ? nil : byes.join(";"))

      out << row
    end
  end

  csv
end

server = WEBrick::HTTPServer.new(Port: 4567, BindAddress: "127.0.0.1")
trap("INT") { server.shutdown }

server.mount_proc "/" do |req, res|
  if req.request_method == "GET"
    # Serve index.html by default.
    path = req.path
    if path == "/" || path.empty?
      index_path = File.join(PUBLIC_DIR, "index.html")
      serve_static(index_path, res) || (res.status = 404; res.body = "Not found")
    else
      # Strip leading slash and serve from public dir.
      rel = path.sub(%r{^/}, "")
      serve_static(File.join(PUBLIC_DIR, rel), res) || (res.status = 404; res.body = "Not found")
    end
  else
    res.status = 405
    res.body = "Method not allowed"
  end
end

server.mount_proc "/generate" do |req, res|
  if req.request_method != "POST"
    res.status = 405
    res.body = "Method not allowed"
    next
  end

  begin
    raw = req.body
    payload = JSON.parse(raw)
    schedule = DodgeballScheduler.generate(payload)
    csv = build_csv(schedule)
    schedule["csv"] = csv

    res.status = 200
    res["Content-Type"] = "application/json; charset=utf-8"
    res.body = JSON.generate(schedule)
  rescue DodgeballScheduler::ScheduleError => e
    res.status = 400
    res["Content-Type"] = "application/json; charset=utf-8"
    res.body = JSON.generate({ "error" => e.message })
  rescue JSON::ParserError
    res.status = 400
    res["Content-Type"] = "application/json; charset=utf-8"
    res.body = JSON.generate({ "error" => "Invalid JSON payload" })
  rescue => e
    res.status = 500
    res["Content-Type"] = "application/json; charset=utf-8"
    res.body = JSON.generate({ "error" => e.class.to_s + ": " + e.message })
  end
end

puts "Round Robin Scheduler running at http://127.0.0.1:4567"
server.start

