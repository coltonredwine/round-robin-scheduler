require "json"

# Dodgeball round-robin schedule generator.
#
# Scheduling model:
# - Even teams: split into two equal sides A and B; each team plays `gamesPerTeam`
#   distinct opponents on the other side (bipartite union of matchings).
# - Odd teams: each team plays `gamesPerTeam` distinct opponents in a circulant
#   regular graph (requires gamesPerTeam even and total matchups integer).
#
# Courts are used two teams at a time; each round is a matching:
# - No team plays more than once per round.
# - No head-to-head pairing repeats across rounds.
#
# Optional refs:
# - For each round, we assign `ref_slots_per_round` ref teams drawn from teams that
#   are not playing (off/bye eligible).
# - The rest of the off teams are "bye" for that round.
class DodgeballScheduler
  class ScheduleError < StandardError; end

  def self.parse_int_param(params, key, default: nil, min: nil, error_label: nil)
    raw = params[key]
    raw = default if (raw.nil? || raw == "") && !default.nil?
    raise ScheduleError, "#{error_label || key} is required." if raw.nil? || raw == ""
    v = Integer(raw)
    if !min.nil? && v < min
      raise ScheduleError, "#{error_label || key} must be at least #{min}."
    end
    v
  end

  def self.generate(params)
    teams = parse_int_param(params, "teams", min: 2, error_label: "Teams")
    courts = parse_int_param(params, "courts", min: 1, error_label: "Courts")

    include_ref = !!params.fetch("includeRef")
    ref_slots_per_round = include_ref ? parse_int_param(params, "refSlotsPerRound", default: 0, min: 0, error_label: "Ref slots per round") : 0
    ref_label_mode = include_ref ? (params.fetch("refLabelMode", "paired") || "paired") : "none" # "paired" or "unpaired"

    include_round_time = !!params.fetch("includeRoundTime")
    # Always enabled: avoid schedules where a team's games are all consecutive when possible.
    avoid_consecutive_play = true

    round_length_minutes =
      if include_round_time
        parse_int_param(params, "roundLengthMinutes", default: 15, min: 1, error_label: "Round length")
      else
        15
      end
    start_time = include_round_time ? (params["startTime"] || "10:00") : "10:00" # "HH:MM"
    ensure_each_team_has_bye = !!params.fetch("ensureEachTeamHasBye")

    raise ScheduleError, "Teams must be at least 2 (odd or even team counts are supported)." if teams < 2

    # Max distinct opponents per team without repeats is always teams - 1.
    max_games_even = teams - 1
    max_games_odd = teams - 1

    # Default games per team: even → half field; odd → up to 8 (capped by n−1), at least 2 and even.
    default_games =
      if teams.even?
        (teams / 2)
      else
        g = [[8, max_games_odd].min, 2].max
        g -= 1 if g.odd?
        g
      end
    games_per_team = params.key?("gamesPerTeam") ? parse_int_param(params, "gamesPerTeam", error_label: "Games per team") : default_games

    if teams.even?
      raise ScheduleError, "Games per team must be between 1 and #{max_games_even}." if games_per_team < 1 || games_per_team > max_games_even
    else
      raise ScheduleError, "Games per team must be between 2 and #{max_games_odd}." if games_per_team < 2 || games_per_team > max_games_odd
      raise ScheduleError, "Games per team must be an even number when using an odd team count." if games_per_team.odd?
    end

    raise ScheduleError, "Total games must be even (teams × games per team must be even)." if (teams * games_per_team).odd?

    total_games = (teams * games_per_team) / 2

    warnings = []
    if include_ref
      raise ScheduleError, "refSlotsPerRound must be >= 0" if ref_slots_per_round < 0
    end

    # Choose a per-round game cap so that every round can accommodate refs.
    # If a round has k games, then it uses 2k playing teams, leaving `teams - 2k` off teams.
    # We require (teams - 2k) >= ref_slots_per_round for every round, so k <= floor((teams - refSlots)/2).
    max_games_per_round = teams / 2 # floor: at most this many simultaneous games
    if include_ref
      max_games_by_refs = ((teams - ref_slots_per_round) / 2).floor
      game_cap = [courts, max_games_per_round, max_games_by_refs].min
    else
      game_cap = [courts, max_games_per_round].min
    end

    if include_ref && game_cap < courts
      warnings << "Some courts will be idle to make room for ref slots (refSlotsPerRound requires extra off teams)."
    end

    raise ScheduleError, "Too many ref slots for the given team/court counts." if game_cap < 1 && include_ref
    raise ScheduleError, "Not enough capacity to schedule any games." if game_cap < 1

    # Determine number of rounds needed (minimum) and generate the core matchups.
    # We always try to pack rounds as tightly as possible (avoid “mostly empty court” rounds),
    # subject to required byes/refs constraints.

    # Each team can play at most once per round.
    min_rounds_by_games = games_per_team

    # Capacity constraint.
    min_rounds_by_capacity = (total_games.to_f / game_cap).ceil.to_i

    schedule_core = nil
    rounds_total = nil
    effective_ref_slots = include_ref ? ref_slots_per_round : 0
    if ensure_each_team_has_bye
      if include_ref
        denom = teams - effective_ref_slots
        raise ScheduleError, "Cannot ensure byes when refSlotsPerRound >= teams." if denom <= 0
        # Each team plays exactly games_per_team games, so off rounds per team = r - games_per_team.
        # Each off event is either a ref or a bye. Total bye events across the tournament:
        # byeEvents = r*(teams - refSlotsPerRound) - teams*gamesPerTeam
        # Need byeEvents >= teams so every team can have at least one bye.
        r_needed = ((teams * (games_per_team + 1)).to_f / denom).ceil.to_i
      else
        # With no refs, byeEvents = teams*(r - games_per_team) and we just need r - games_per_team >= 1
        r_needed = games_per_team + 1
      end
    else
      r_needed = nil
    end

    rounds_min = [min_rounds_by_games, min_rounds_by_capacity].max
    rounds_min = [rounds_min, r_needed].max if r_needed

    # Build a d-regular simple graph of matchups (no repeats), then pack into rounds.
    # - For even n, we can support any d in [1..n-1].
    # - For odd n, d must be even.
    edges = if teams.even?
            build_circulant_edges_even(teams: teams, games_per_team: games_per_team)
          else
            build_circulant_edges_odd(teams: teams, games_per_team: games_per_team)
          end

    # Try to find a tight packing starting at rounds_min; only increase rounds if needed.
    rmax = rounds_min + teams + 10
    (rounds_min..rmax).each do |r|
      begin
        schedule_core = pack_edges_into_rounds(edges: edges, teams: teams, rounds: r, cap: game_cap)
        rounds_total = r
        break
      rescue ScheduleError
        # try a larger number of rounds
      end
    end
    raise ScheduleError, "Unable to generate schedule for given parameters." if schedule_core.nil?

    # Expand into court slots (edges already use global team indices 0..teams-1).
    rounds = schedule_core.map do |edge_list|
      games_on_courts = Array.new(courts)
      edge_list.each_with_index do |(t1, t2), ci|
        break if ci >= courts
        games_on_courts[ci] = [t1, t2]
      end
      games_on_courts
    end

    # Optional: reorder rounds to reduce “all games back-to-back” patterns.
    if avoid_consecutive_play && games_per_team > 1
      reordered, reorder_warning = reorder_rounds_for_consecutive_play(
        rounds: rounds,
        teams: teams,
        games_per_team: games_per_team,
        attempts: 150
      )
      if reorder_warning
        warnings << reorder_warning
      end
      rounds = reordered
    end

    # Determine off teams per round and assign refs/byes.
    rounds_detail = []
    ref_slot_labels = []
    if include_ref
      if ref_label_mode == "paired" && ref_slots_per_round.positive?
        # Teams ref two courts per slot: (1&2), (3&4), …; odd final court without a pair uses "Ref (n)".
        # Fewer slots → first N pair columns; more slots → pair columns plus generic Ref columns.
        full = build_pair_ref_slot_labels(courts)
        ref_slot_labels = if ref_slots_per_round <= full.length
          full.take(ref_slots_per_round).map.with_index { |h, i| h.merge("slotIndex" => i) }
        else
          base = full.map.with_index { |h, i| h.merge("slotIndex" => i) }
          (full.length...ref_slots_per_round).each do |i|
            base << {
              "slotIndex" => i,
              "label" => "Ref (slot #{i + 1})",
              "pairCourts" => []
            }
          end
          base
        end
      elsif ref_slots_per_round == courts
        # One ref slot per court.
        ref_slot_labels = (0...courts).map do |i|
          { "slotIndex" => i, "label" => format_ref_label_from_courts([i + 1]), "pairCourts" => [i + 1] }
        end
      elsif ref_slots_per_round == 1
        ref_slot_labels = [
          {
            "slotIndex" => 0,
            "label" => format_ref_label_from_courts((1..courts).to_a),
            "pairCourts" => (1..courts).to_a
          }
        ]
      else
        ref_slot_labels = (0...ref_slots_per_round).map do |i|
          { "slotIndex" => i, "label" => "Ref (slot #{i + 1})" }
        end
      end
    end

    # We'll do multiple attempts to balance refs evenly.
    attempts = 500
    best = nil
    srand(1234)

    attempts.times do |att|
      srand(1234 + att)
      ref_count = Array.new(teams, 0)
      bye_count = Array.new(teams, 0)

      round_ref_assignments = Array.new(rounds_total) { [] } # per round, list of team indices
      round_byes = Array.new(rounds_total) { [] }             # per round, list of team indices not playing and not ref

      ok = true

      (0...rounds_total).each do |ri|
        playing = Array.new(teams, false)
        rounds[ri].each do |game|
          next if game.nil?
          t1, t2 = game
          playing[t1] = true
          playing[t2] = true
        end

        off_teams = []
        (0...teams).each do |t|
          off_teams << t unless playing[t]
        end

        if include_ref
          # Cap refs by eligible off teams only — not by active_games (peer refs cover court pairs even when some courts are idle).
          ref_slots_this_round = [ref_slots_per_round, off_teams.length].min

          # Choose the ref teams: lowest current ref_count first, random tie-break.
          off_teams.sort_by! { |t| [ref_count[t], rand] }
          chosen = off_teams.first(ref_slots_this_round)
          chosen.each { |t| ref_count[t] += 1 }

          byes = off_teams.drop(ref_slots_this_round)
          byes.each { |t| bye_count[t] += 1 }

          round_ref_assignments[ri] = chosen
          round_byes[ri] = byes
        else
          # No refs; all off teams are byes.
          off_teams.each { |t| bye_count[t] += 1 }
          round_ref_assignments[ri] = []
          round_byes[ri] = off_teams
        end
      end

      next unless ok

      if ensure_each_team_has_bye
        next unless (0...teams).all? { |t| bye_count[t] >= 1 }
      end

      # Score secondary objectives:
      # 1) Minimize consecutive break streaks (break = ref or bye)
      # 2) Minimize adjacent break pairs and spacing irregularity
      # 3) Minimize ref-count imbalance
      break_metrics = compute_break_metrics(
        round_ref_assignments: round_ref_assignments,
        round_byes: round_byes,
        teams: teams,
        rounds_total: rounds_total
      )

      # Keep existing ref balance terms as tertiary tie-breakers.
      maxc = ref_count.max
      minc = ref_count.min
      range = maxc - minc
      mean = ref_count.sum.to_f / ref_count.length
      variance = ref_count.map { |x| (x - mean) ** 2 }.sum / ref_count.length
      score = [
        break_metrics[:max_break_streak_overall],
        break_metrics[:adjacent_break_pairs_total],
        break_metrics[:spacing_penalty_total],
        range,
        maxc,
        variance,
      ]

      better = false
      if best.nil?
        better = true
      else
        best_score = best[:score]
        if score[0] < best_score[0]
          better = true
        elsif score[0] == best_score[0] && score[1] < best_score[1]
          better = true
        elsif score[0] == best_score[0] && score[1] == best_score[1] && score[2] < best_score[2]
          better = true
        elsif score[0] == best_score[0] && score[1] == best_score[1] && score[2] == best_score[2] && score[3] < best_score[3]
          better = true
        elsif score[0] == best_score[0] && score[1] == best_score[1] && score[2] == best_score[2] && score[3] == best_score[3] && score[4] < best_score[4]
          better = true
        elsif score[0] == best_score[0] && score[1] == best_score[1] && score[2] == best_score[2] && score[3] == best_score[3] && score[4] == best_score[4] && score[5] < best_score[5]
          better = true
        end
      end

      if better
        best = {
          score: score,
          ref_count: ref_count,
          bye_count: bye_count,
          round_ref_assignments: round_ref_assignments.map(&:dup),
          round_byes: round_byes.map(&:dup),
        }
      end
    end

    raise ScheduleError, "Not enough teams to peer ref all courts. Increase the number of teams, or reduce the number of courts." if best.nil?

    # Build final rounds_detail structure for UI/CSV.
    (0...rounds_total).each do |ri|
      game_pairs = rounds[ri]
      refs = []
      if include_ref
        chosen = best[:round_ref_assignments][ri]
        k = chosen.length
        permuted = permute_refs_to_slots(
          chosen: chosen,
          ri: ri,
          rounds: rounds,
          ref_slot_labels: ref_slot_labels,
          ref_slots_this_round: k
        )
        permuted.each_with_index do |t, i|
          label = ref_slot_labels[i] ? ref_slot_labels[i]["label"] : "Ref #{i + 1}"
          ref_obj = { "slotIndex" => i, "slotLabel" => label, "team" => t }
          ref_obj["pairCourts"] = ref_slot_labels[i]["pairCourts"] if ref_slot_labels[i] && ref_slot_labels[i]["pairCourts"]
          refs << ref_obj
        end
      end

      byes = best[:round_byes][ri]
      rounds_detail << { "games" => game_pairs, "refs" => refs, "byes" => byes }
    end

    # Validate schedule core constraints.
    verify_core!(schedule_core: schedule_core, teams: teams, rounds: rounds_total, cap: game_cap, games_per_team: games_per_team)

    max_consecutive_games_by_team, max_consecutive_games_overall = compute_max_consecutive_games(
      rounds: rounds,
      teams: teams
    )

    # Compute time labels for UI (not included in CSV by default).
    times = build_times(start_time: start_time, round_length_minutes: round_length_minutes, rounds_total: rounds_total)

    {
      "teams" => teams,
      "courts" => courts,
      "side" => nil,
      "roundsTotal" => rounds_total,
      "gamesPerTeam" => games_per_team,
      "includeRef" => include_ref,
      "refSlotsPerRound" => ref_slots_per_round,
      "refSlotLabels" => ref_slot_labels,
      "roundLengthMinutes" => round_length_minutes,
      "startTime" => start_time,
      "includeRoundTime" => include_round_time,
      "rounds" => rounds_detail,
      "teamGameCounts" => Array.new(teams, games_per_team),
      "teamRefCounts" => best[:ref_count],
      "teamByeCounts" => best[:bye_count],
      "maxConsecutiveGamesByTeam" => max_consecutive_games_by_team,
      "maxConsecutiveGamesOverall" => max_consecutive_games_overall,
      "roundTimes" => times,
      "warnings" => warnings,
    }
  end

  # --- Core schedule generation (K_{side,side} into rounds of matchings) ---

  def self.generate_core_constructive(side:, cap:)
    rounds = []
    side.times do |color|
      matching = []
      side.times do |a|
        b = (a + color) % side
        matching << [a, b]
      end
      matching.each_slice(cap) do |slice|
        rounds << slice
      end
    end
    rounds
  end

  # Constructive partial schedule:
  # - Take `matchings` perfect matchings from the cyclic decomposition.
  # - Union of these matchings gives an m-regular bipartite subgraph where each team
  #   plays exactly `matchings` opponents on the opposite side (no repeats).
  def self.generate_core_constructive_partial(side:, matchings:, cap:)
    rounds = []
    matchings.times do |color|
      matching = []
      side.times do |a|
        b = (a + color) % side
        matching << [a, b]
      end
      matching.each_slice(cap) do |slice|
        rounds << slice
      end
    end
    rounds
  end

  # General-purpose packer: assigns each edge to a round such that:
  # - each round has <= cap edges
  # - no team appears in more than one game in a round (matching)
  def self.pack_edges_into_rounds(edges:, teams:, rounds:, cap:)
    r_total = rounds
    raise ScheduleError, "rounds must be >= 1" if r_total < 1

    used = Array.new(teams) { Array.new(r_total, false) }
    count = Array.new(r_total, 0)
    roundEdges = Array.new(r_total) { [] }

    edges2 = edges.sort
    n = edges2.length
    assign = Array.new(n)

    get_candidates = lambda do |a, b|
      cands = []
      r_total.times do |r|
        next if used[a][r] || used[b][r]
        next if count[r] >= cap
        cands << r
      end
      cands
    end

    choose_next = lambda do
      best_i = nil
      best_c = nil
      n.times do |i|
        next unless assign[i].nil?
        a, b = edges2[i]
        c = get_candidates.call(a, b)
        if best_i.nil? || c.length < best_c.length
          best_i = i
          best_c = c
          return [best_i, best_c] if c.length <= 1
        end
        return [best_i, best_c] if best_c && best_c.empty?
      end
      [best_i, best_c]
    end

    apply_edge = lambda do |i, r|
      a, b = edges2[i]
      return false if used[a][r] || used[b][r] || count[r] >= cap
      used[a][r] = true
      used[b][r] = true
      count[r] += 1
      roundEdges[r] << [a, b]
      assign[i] = r
      true
    end

    undo_edge = lambda do |i, r|
      a, b = edges2[i]
      used[a][r] = false
      used[b][r] = false
      count[r] -= 1
      arr = roundEdges[r]
      pos = arr.index([a, b])
      raise ScheduleError, "Edge not found on undo" if pos.nil?
      arr.delete_at(pos)
      assign[i] = nil
    end

    # Symmetry: pre-assign edges incident to team 0 into distinct early rounds if possible.
    pre = []
    edges2.each_with_index do |(a, b), i|
      next unless a == 0 || b == 0
      pre << i
    end
    if r_total >= pre.length
      pre.each_with_index do |i, r|
        apply_edge.call(i, r)
      end
    end

    steps = 0
    max_steps = 3_000_000
    rec = nil
    rec = lambda do
      steps += 1
      raise ScheduleError, "Packing timeout" if steps > max_steps
      i, cands = choose_next.call
      return true if i.nil?
      return false if cands.empty?

      # Prefer filling emptier rounds first (keeps utilization high early).
      cands.sort_by! { |rr| count[rr] + (rand * 0.01) }
      cands.each do |r|
        next unless apply_edge.call(i, r)
        return true if rec.call
        undo_edge.call(i, r)
      end
      false
    end

    12.times do |attempt|
      srand(2000 + attempt)
      begin
        return roundEdges if rec.call
      rescue ScheduleError
        # fallthrough
      end
    end

    raise ScheduleError, "Unable to pack edges into #{r_total} rounds (cap #{cap})"
  end

  def self.generate_core_backtracking(side:, rounds:, cap:)
    # Backtracking edge-coloring with max matching size `cap` per round.
    r_total = rounds
    raise ScheduleError, "rounds must be >= side" if r_total < side

    numEdges = side * side
    idx_of = ->(a, b) { a * side + b }
    max_steps = 2_000_000

    30.times do |t|
      srand(1000 + t)

      usedA = Array.new(side) { Array.new(r_total, false) }
      usedB = Array.new(side) { Array.new(r_total, false) }
      count = Array.new(r_total, 0)
      roundEdges = Array.new(r_total) { [] } # list of [a,b] per round
      assign = Array.new(numEdges)

      # Symmetry breaking: fix all edges (A0,Bb) into rounds rb=b.
      side.times do |b|
        r = b
        usedA[0][r] = true
        usedB[b][r] = true
        count[r] += 1
        roundEdges[r] << [0, b]
        assign[idx_of.call(0, b)] = r
      end

      get_candidates = lambda do |a, b|
        cands = []
        r_total.times do |r|
          next if usedA[a][r]
          next if usedB[b][r]
          next if count[r] >= cap
          cands << r
        end
        cands
      end

      choose_next = lambda do
        best_idx = nil
        best_cands = nil
        numEdges.times do |idx|
          next unless assign[idx].nil?
          a = idx / side
          b = idx % side
          cands = get_candidates.call(a, b)
          if best_idx.nil? || cands.length < best_cands.length
            best_idx = idx
            best_cands = cands
            return [best_idx, best_cands] if cands.length <= 1
          end
          return [best_idx, best_cands] if best_cands && best_cands.length == 0
        end
        [best_idx, best_cands]
      end

      apply_edge = lambda do |idx, r|
        a = idx / side
        b = idx % side
        return false if usedA[a][r] || usedB[b][r] || count[r] >= cap
        usedA[a][r] = true
        usedB[b][r] = true
        count[r] += 1
        roundEdges[r] << [a, b]
        assign[idx] = r
        true
      end

      undo_edge = lambda do |idx, r|
        a = idx / side
        b = idx % side
        usedA[a][r] = false
        usedB[b][r] = false
        count[r] -= 1
        arr = roundEdges[r]
        pos = arr.index([a, b])
        raise ScheduleError, "Edge not found on undo" if pos.nil?
        arr.delete_at(pos)
        assign[idx] = nil
      end

      steps = 0
      rec = nil
      rec = lambda do
        steps += 1
        raise ScheduleError, "Backtracking timeout" if steps > max_steps

        idx, cands = choose_next.call
        return true if idx.nil?
        return false if cands.empty?

        cands.sort_by! { |rr| count[rr] + (rand * 0.01) }

        cands.each do |r|
          next unless apply_edge.call(idx, r)
          return true if rec.call
          undo_edge.call(idx, r)
        end
        false
      end

      return roundEdges if rec.call
    end

    raise ScheduleError, "Backtracking failed"
  end

  def self.verify_core!(schedule_core:, teams:, rounds:, cap:, games_per_team:)
    seen = {}
    team_counts = Array.new(teams, 0)

    schedule_core.each_with_index do |edges, ri|
      raise ScheduleError, "Round #{ri} exceeds cap" if edges.length > cap
      used_in_round = {}

      edges.each do |a, b|
        raise ScheduleError, "Team #{a + 1} plays twice in round #{ri}" if used_in_round[a]
        raise ScheduleError, "Team #{b + 1} plays twice in round #{ri}" if used_in_round[b]
        used_in_round[a] = true
        used_in_round[b] = true

        key = [a, b].minmax.join("-")
        raise ScheduleError, "Duplicate matchup detected: #{key}" if seen[key]
        seen[key] = true

        team_counts[a] += 1
        team_counts[b] += 1
      end
    end

    expected_edges = (teams * games_per_team) / 2
    raise ScheduleError, "Unexpected number of matchups scheduled: #{seen.length}" unless seen.length == expected_edges

    (0...teams).each do |t|
      raise ScheduleError, "Team #{t + 1} plays #{team_counts[t]} matches, expected #{games_per_team}" unless team_counts[t] == games_per_team
    end
  end

  # Even n: circulant regular graph — supports any degree d in [1..n-1].
  # Construction:
  # - Add +/-k steps for k=1..floor(d/2) (contributes 2*floor(d/2) degree)
  # - If d is odd, add the perfect matching i <-> i + n/2 (contributes +1 degree)
  def self.build_circulant_edges_even(teams:, games_per_team:)
    n = teams
    d = games_per_team
    edges = []

    (0...n).each do |i|
      (1..(d / 2)).each do |k|
        j = (i + k) % n
        edges << [i, j].minmax
        j2 = (i - k) % n
        edges << [i, j2].minmax
      end

      if d.odd?
        j = (i + (n / 2)) % n
        edges << [i, j].minmax
      end
    end

    edges.uniq!
    raise ScheduleError, "Internal error building circulant edge set" unless edges.length == (n * d) / 2
    edges
  end

  # Odd n: circulant regular graph — each team plays games_per_team distinct opponents (even degree).
  def self.build_circulant_edges_odd(teams:, games_per_team:)
    n = teams
    d = games_per_team
    edges = []
    (0...n).each do |i|
      (1..d / 2).each do |k|
        j = (i + k) % n
        edges << [i, j].minmax
        j2 = (i - k) % n
        edges << [i, j2].minmax
      end
    end
    edges.uniq!
    raise ScheduleError, "Internal error building circulant edge set" unless edges.length == (n * d) / 2

    edges
  end

  def self.format_ref_label_from_courts(courts_list)
    inside = courts_list.map(&:to_s).join("&")
    "Ref (#{inside})"
  end

  # Ref columns for "teams ref 2 courts": Ref (1&2), Ref (3&4), …; if courts is odd, last column is Ref (n).
  def self.build_pair_ref_slot_labels(courts)
    out = []
    court = 1
    idx = 0
    while court <= courts
      if court + 1 <= courts
        out << {
          "slotIndex" => idx,
          "label" => format_ref_label_from_courts([court, court + 1]),
          "pairCourts" => [court, court + 1]
        }
        court += 2
      else
        out << {
          "slotIndex" => idx,
          "label" => format_ref_label_from_courts([court]),
          "pairCourts" => [court]
        }
        court += 1
      end
      idx += 1
    end
    out
  end

  def self.court_indices_for_team(round_games, team)
    return [] unless round_games

    cis = []
    round_games.each_with_index do |g, ci|
      next unless g
      t1, t2 = g
      cis << ci if t1 == team || t2 == team
    end
    cis
  end

  # Assign ref teams to slots: prefer slot covering a court they play on next round, else a court they played on last round.
  def self.permute_refs_to_slots(chosen:, ri:, rounds:, ref_slot_labels:, ref_slots_this_round:)
    return chosen if chosen.empty?

    k = ref_slots_this_round
    labels = ref_slot_labels.take(k)
    return chosen if labels.empty?

    next_r = (ri + 1 < rounds.length) ? rounds[ri + 1] : nil
    prev_r = (ri > 0) ? rounds[ri - 1] : nil

    teams_left = chosen.dup
    result = Array.new(k)

    k.times do |j|
      label = labels[j]
      slot_courts_0 = (label && label["pairCourts"]) ? label["pairCourts"].map { |c| c - 1 } : []

      best_ts = []
      best_score = -1
      teams_left.each do |t|
        next_c = next_r ? court_indices_for_team(next_r, t) : []
        prev_c = prev_r ? court_indices_for_team(prev_r, t) : []
        sc = 0
        sc += 100 if slot_courts_0.any? && next_c.any? { |c| slot_courts_0.include?(c) }
        sc += 50 if slot_courts_0.any? && prev_c.any? { |c| slot_courts_0.include?(c) }
        if sc > best_score
          best_score = sc
          best_ts = [t]
        elsif sc == best_score
          best_ts << t
        end
      end

      pick = (best_ts.empty? ? teams_left : best_ts).sample
      result[j] = pick
      teams_left.delete(pick)
    end

    result
  end

  # Greedily reorder rounds so no team plays all of its games consecutively.
  # This is a heuristic; if it can't find a fully valid ordering, it returns the original order with a warning.
  def self.reorder_rounds_for_consecutive_play(rounds:, teams:, games_per_team:, attempts:)
    rounds_total = rounds.length
    return [rounds, nil] if games_per_team <= 1

    # Precompute which teams play in which round.
    playing = Array.new(rounds_total) { Array.new(teams, false) }
    playing_count = Array.new(rounds_total, 0)

    rounds_total.times do |ri|
      rounds[ri].each do |game|
        next unless game
        t1, t2 = game
        playing[ri][t1] = true
        playing[ri][t2] = true
      end
      playing_count[ri] = playing[ri].count(true)
    end

    best_failures = nil
    best_order = nil

    attempts.times do
      remaining = (0...rounds_total).to_a.shuffle
      streak = Array.new(teams, 0)
      max_streak = Array.new(teams, 0)
      order = []
      valid = true

      while !remaining.empty?
        best_choice = nil
        best_score = nil

        # Prefer a choice that does not immediately complete a full consecutive block for any team.
        remaining.each do |ri|
          violates = false
          score = 0

          teams.times do |t|
            if playing[ri][t]
              if streak[t] == games_per_team - 1
                violates = true
                break
              end
              score += (streak[t] + 1)
            end
          end
          next if violates

          # Higher off-team count is good because it resets more streaks.
          off_count = teams - playing_count[ri]
          score -= off_count * 0.01

          if best_choice.nil? || score < best_score
            best_choice = ri
            best_score = score
          end
        end

        # If every remaining choice violates, relax and pick the least-worst.
        if best_choice.nil?
          valid = false
          remaining.each do |ri|
            score = 0
            teams.times do |t|
              score += playing[ri][t] ? (streak[t] + 1) : 0
            end
            off_count = teams - playing_count[ri]
            score -= off_count * 0.01
            if best_choice.nil? || score < best_score
              best_choice = ri
              best_score = score
            end
          end
        end

        order << best_choice
        remaining.delete(best_choice)

        # Update streaks
        teams.times do |t|
          if playing[best_choice][t]
            streak[t] += 1
            max_streak[t] = [max_streak[t], streak[t]].max
          else
            streak[t] = 0
          end
        end

        # Early exit if already invalid.
        if max_streak.any? { |s| s >= games_per_team }
          valid = false
        end
      end

      if valid && max_streak.all? { |s| s < games_per_team }
        reordered = order.map { |ri| rounds[ri] }
        return [reordered, nil]
      end

      failure_count = max_streak.count { |s| s >= games_per_team }
      if best_failures.nil? || failure_count < best_failures
        best_failures = failure_count
        best_order = order
      end
    end

    if best_order
      reordered = best_order.map { |ri| rounds[ri] }
      return [reordered, "Could not completely avoid consecutive games for every team; using best available ordering."]
    end

    [rounds, "Could not compute a better round ordering."]
  end

  def self.compute_max_consecutive_games(rounds:, teams:)
    streak = Array.new(teams, 0)
    max_streak = Array.new(teams, 0)

    rounds.each do |round_games|
      playing = Array.new(teams, false)
      round_games.each do |g|
        next if g.nil?
        t1, t2 = g
        playing[t1] = true
        playing[t2] = true
      end

      teams.times do |t|
        if playing[t]
          streak[t] += 1
          max_streak[t] = [max_streak[t], streak[t]].max
        else
          streak[t] = 0
        end
      end
    end

    [max_streak, max_streak.max || 0]
  end

  # Breaks are rounds where a team is not playing and is either reffing or on bye.
  # Returns metrics used for secondary optimization:
  # - max_break_streak_overall: largest consecutive break run for any team
  # - adjacent_break_pairs_total: total "...break, break..." pairs across all teams
  # - spacing_penalty_total: sum of per-team gap variance (lower = more even break spacing)
  def self.compute_break_metrics(round_ref_assignments:, round_byes:, teams:, rounds_total:)
    max_break_streak_overall = 0
    adjacent_break_pairs_total = 0
    spacing_penalty_total = 0.0

    (0...teams).each do |t|
      breaks = Array.new(rounds_total, false)
      (0...rounds_total).each do |ri|
        breaks[ri] = round_ref_assignments[ri].include?(t) || round_byes[ri].include?(t)
      end

      run = 0
      team_max_run = 0
      (0...rounds_total).each do |ri|
        if breaks[ri]
          run += 1
          team_max_run = run if run > team_max_run
          adjacent_break_pairs_total += 1 if ri > 0 && breaks[ri - 1]
        else
          run = 0
        end
      end
      max_break_streak_overall = team_max_run if team_max_run > max_break_streak_overall

      break_positions = []
      breaks.each_with_index { |is_break, ri| break_positions << ri if is_break }
      next if break_positions.length <= 1

      gaps = []
      break_positions.each_cons(2) { |a, b| gaps << (b - a) }
      mean_gap = gaps.sum.to_f / gaps.length
      team_gap_var = gaps.map { |g| (g - mean_gap) ** 2 }.sum / gaps.length
      spacing_penalty_total += team_gap_var
    end

    {
      max_break_streak_overall: max_break_streak_overall,
      adjacent_break_pairs_total: adjacent_break_pairs_total,
      spacing_penalty_total: spacing_penalty_total
    }
  end

  def self.build_times(start_time:, round_length_minutes:, rounds_total:)
    unless start_time =~ /^\d{1,2}:\d{2}$/
      raise ScheduleError, "startTime must be in HH:MM (e.g. 10:00)"
    end
    hh, mm = start_time.split(":").map(&:to_i)
    raise ScheduleError, "startTime hour must be 0-23" if hh < 0 || hh > 23
    raise ScheduleError, "startTime minute must be 0-59" if mm < 0 || mm > 59

    start_total = hh * 60 + mm

    times = []
    rounds_total.times do |ri|
      s = start_total + ri * round_length_minutes
      e = s + round_length_minutes
      times << { "start" => format_time_12h(s), "end" => format_time_12h(e) }
    end
    times
  end

  def self.format_time_12h(total_minutes)
    total_minutes %= (24 * 60)
    h = total_minutes / 60
    m = total_minutes % 60
    ampm = h >= 12 ? "PM" : "AM"
    h12 = h % 12
    h12 = 12 if h12 == 0
    "#{h12}:#{m.to_s.rjust(2, '0')} #{ampm}"
  end
end

