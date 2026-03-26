# Generates a dodgeball round-robin schedule for 16 teams on 6 courts.
# Model: split teams into two sides of 8. Each team plays all 8 teams on the other side (64 head-to-head games total).
# Then edge-color K8,8 into 11 rounds (time slots) where each round is a matching (no team plays twice) and has <=6 games.
# We further set exact round capacities: 9 rounds with 6 games and 2 rounds with 5 games.

R = 12
SIDE = 8
COURTS = 6

# Round capacities. Total games = 9*6 + 2*5 = 64.
CAP = Array.new(R, COURTS)
CAP[9] = 5
CAP[10] = 5
CAP[11] = 0

# Team ids: A = 0..7, B = 8..15.
# We'll index B as 0..7 for internal bookkeeping.

# usedA[a][r] => team A+a has already been scheduled in round r
# usedB[b][r] => team B+b (actual team id 8+b) has already been scheduled in round r
usedA = Array.new(SIDE) { Array.new(R, false) }
usedB = Array.new(SIDE) { Array.new(R, false) }
count = Array.new(R, 0)
roundEdges = Array.new(R) { [] } # each entry: [a, b]

# Edge (a,b) where a in [0..7], b in [0..7] corresponds to matchup: (team a) vs (team 8+b)
# We'll use idx = a*SIDE + b.
numEdges = SIDE * SIDE
assign = Array.new(numEdges, nil)

idx_of = ->(a,b){ a*SIDE + b }

# Symmetry breaking: pre-assign all edges from A0 to every B vertex.
# Put (A0, Bj) into round j for j=0..7.
(0...SIDE).each do |b|
  r = b
  a = 0
  # validate capacities
  raise "Capacity violation at round #{r}" if count[r] >= CAP[r]
  usedA[a][r] = true
  usedB[b][r] = true
  count[r] += 1
  roundEdges[r] << [a, b]
  assign[idx_of.call(a,b)] = r
end

# Pre-verify no round exceeds capacity.
(0...R).each do |r|
  raise "Overfull round #{r}" if count[r] > CAP[r]
end

edges_total_assigned = assign.count { |x| !x.nil? }

# Candidate rounds for edge (a,b)
get_candidates = lambda do |a,b|
  candidates = []
  (0...R).each do |r|
    next if usedA[a][r]
    next if usedB[b][r]
    next if count[r] >= CAP[r]
    candidates << r
  end
  candidates
end

# Choose next unassigned edge with MRV heuristic.
choose_next = lambda do
  best_idx = nil
  best_cands = nil
  (0...numEdges).each do |idx|
    next unless assign[idx].nil?
    a = idx / SIDE
    b = idx % SIDE
    cands = get_candidates.call(a,b)
    if best_idx.nil? || cands.length < best_cands.length
      best_idx = idx
      best_cands = cands
      return [best_idx, best_cands] if cands.length <= 1
    end
    if best_cands && cands.length == 0
      return [best_idx, best_cands]
    end
  end
  [best_idx, best_cands]
end

# Apply assignment
apply_edge = lambda do |idx, r|
  a = idx / SIDE
  b = idx % SIDE
  raise "Invalid assignment" if usedA[a][r] || usedB[b][r] || count[r] >= CAP[r]
  usedA[a][r] = true
  usedB[b][r] = true
  count[r] += 1
  roundEdges[r] << [a,b]
  assign[idx] = r
end

undo_edge = lambda do |idx, r|
  a = idx / SIDE
  b = idx % SIDE
  usedA[a][r] = false
  usedB[b][r] = false
  count[r] -= 1
  # remove edge [a,b] from roundEdges[r]
  # (there should be exactly one)
  arr = roundEdges[r]
  pos = arr.index([a,b])
  raise "Edge not found on undo" if pos.nil?
  arr.delete_at(pos)
  assign[idx] = nil
end

# Order candidate rounds: try rounds with more remaining capacity first? Here, try emptier rounds first.

steps = 0
max_steps_debug = 5_000_000

solve = lambda do
  rec = lambda do
    steps += 1
    raise "Too many steps" if steps > max_steps_debug

    idx, cands = choose_next.call
    return true if idx.nil? # all assigned
    return false if cands.empty?

    # sort by current fullness (ascending), small random tie-breaker
    cands.sort_by! { |rr| count[rr] + (rand * 0.01) }

    cands.each do |r|
      apply_edge.call(idx, r)
      if rec.call
        return true
      end
      undo_edge.call(idx, r)
    end
    false
  end
  rec.call
end

ok = nil
schedule = nil
tries = 20
tries.times do |t|
  srand(1000 + t)
  # reset search state but keep the initial fixed A0 assignments
  # (reinitialize all data structures)
  usedA = Array.new(SIDE) { Array.new(R, false) }
  usedB = Array.new(SIDE) { Array.new(R, false) }
  count = Array.new(R, 0)
  roundEdges = Array.new(R) { [] }
  assign = Array.new(numEdges, nil)

  (0...SIDE).each do |b|
    r = b
    a = 0
    usedA[a][r] = true
    usedB[b][r] = true
    count[r] += 1
    roundEdges[r] << [a,b]
    assign[idx_of.call(a,b)] = r
  end

  get_candidates = lambda do |a,b|
    candidates = []
    (0...R).each do |r|
      next if usedA[a][r]
      next if usedB[b][r]
      next if count[r] >= CAP[r]
      candidates << r
    end
    candidates
  end

  choose_next = lambda do
    best_idx = nil
    best_cands = nil
    (0...numEdges).each do |idx2|
      next unless assign[idx2].nil?
      a = idx2 / SIDE
      b = idx2 % SIDE
      cands = get_candidates.call(a,b)
      if best_idx.nil? || cands.length < best_cands.length
        best_idx = idx2
        best_cands = cands
        return [best_idx, best_cands] if cands.length <= 1
      end
      if best_cands && cands.length == 0
        return [best_idx, best_cands]
      end
    end
    [best_idx, best_cands]
  end

  apply_edge = lambda do |idx, r|
    a = idx / SIDE
    b = idx % SIDE
    return false if usedA[a][r] || usedB[b][r] || count[r] >= CAP[r]
    usedA[a][r] = true
    usedB[b][r] = true
    count[r] += 1
    roundEdges[r] << [a,b]
    assign[idx] = r
    true
  end

  undo_edge = lambda do |idx, r|
    a = idx / SIDE
    b = idx % SIDE
    usedA[a][r] = false
    usedB[b][r] = false
    count[r] -= 1
    arr = roundEdges[r]
    pos = arr.index([a,b])
    raise "Edge not found on undo" if pos.nil?
    arr.delete_at(pos)
    assign[idx] = nil
  end

  steps = 0

  rec = lambda do
    steps += 1
    raise "Too many steps" if steps > max_steps_debug

    idx2, cands = choose_next.call
    return true if idx2.nil?
    return false if cands.empty?

    cands.sort_by! { |rr| count[rr] + (rand * 0.01) }

    cands.each do |r|
      apply_edge.call(idx2, r)
      if rec.call
        return true
      end
      undo_edge.call(idx2, r)
    end
    false
  end

  begin
    if rec.call
      ok = true
      # break with current schedule state in scope? capture by deep copy
      schedule = roundEdges.map { |edges| edges.dup }
      break
    end
  rescue StandardError => e
    # ignore failures; try next seed
  end
end

unless ok
  abort "Failed to find schedule. Try adjusting round capacities or symmetry breaking constraints."
end

# Verification: validate schedule constraints.
def verify_schedule!(schedule, side, r_total)
  seen_pairs = {}
  team_counts = Hash.new(0)

  (0...r_total).each do |r|
    used_in_round = {}
    schedule[r].each do |a, b|
      ta = a # 0..7
      tb = side + b # 8..15
      # no team appears twice in a round
      raise "Team #{ta} plays twice in round #{r}" if used_in_round[ta]
      raise "Team #{tb} plays twice in round #{r}" if used_in_round[tb]
      used_in_round[ta] = true
      used_in_round[tb] = true

      # no duplicate head-to-head match
      x, y = [ta, tb].minmax
      key = "#{x}-#{y}"
      raise "Duplicate matchup #{key}" if seen_pairs[key]
      seen_pairs[key] = true

      team_counts[ta] += 1
      team_counts[tb] += 1
    end
    if schedule[r].length > CAP[r]
      raise "Round #{r} exceeds capacity"
    end
  end

  # each team plays 8 matches because the underlying graph is K8,8
  (0...(2 * side)).each do |t|
    cnt = team_counts[t]
    raise "Team #{t} plays #{cnt}, expected #{side}" if cnt != side
  end

  if seen_pairs.length != side * side
    raise "Unexpected number of unique matchups: #{seen_pairs.length}"
  end
end

verify_schedule!(schedule, SIDE, R)

# Assign refs + byes per round.
# Rule:
# - Each round has 3 ref slots, one for each court pair (1&2), (3&4), (5&6).
# - Ref teams must come from the teams that are not playing that round.
# - Any remaining teams not playing and not assigned as refs are "bye" for that round.
ref_pairs = [
  { court_range: [1, 2], label: "Courts 1-2", slot_idx: 0 },
  { court_range: [3, 4], label: "Courts 3-4", slot_idx: 1 },
  { court_range: [5, 6], label: "Courts 5-6", slot_idx: 2 },
]

all_teams = (0...(2 * SIDE)).to_a

# Build per-round court matchups (for court numbering) and eligible ref teams.
round_courts = Array.new(R) { Array.new(COURTS) }
round_off_teams = Array.new(R) { [] }

(0...R).each do |r|
  edges = schedule[r].map { |a, b| [a, 8 + b] }
  edges.sort_by! { |pair| pair[0] * 100 + pair[1] }

  playing = {}
  (0...COURTS).each do |court_idx|
    if court_idx < edges.length
      t1, t2 = edges[court_idx]
      round_courts[r][court_idx] = [t1, t2]
      playing[t1] = true
      playing[t2] = true
    else
      round_courts[r][court_idx] = nil
    end
  end

  round_off_teams[r] = all_teams.reject { |t| playing[t] }
end

def validate_accounting!(round_courts, round_ref_assignments, round_byes)
  r_total = round_courts.length
  courts = round_courts[0].length

  (0...r_total).each do |r|
    playing = {}
    (0...courts).each do |ci|
      game = round_courts[r][ci]
      next if game.nil?
      playing[game[0]] = true
      playing[game[1]] = true
    end

    refs = {}
    round_ref_assignments[r].each do |t|
      refs[t] = true
    end

    byes = {}
    round_byes[r].each do |t|
      byes[t] = true
    end

    accounted = {}
    playing.keys.each { |t| accounted[t] = :playing }
    refs.keys.each { |t| accounted[t] = :ref }
    byes.keys.each { |t| accounted[t] = :bye }

    raise "Round #{r}: a team is in multiple categories" if accounted.length != (playing.size + refs.size + byes.size)
    raise "Round #{r}: not all teams accounted" if accounted.length != 16
  end
end

# Heuristic search for even ref distribution.
# We try multiple random tie-breakers and pick the best based on:
# 1) minimize (max_ref - min_ref)
# 2) then minimize max_ref
# 3) then minimize variance
def score_ref_counts(ref_count)
  maxc = ref_count.max
  minc = ref_count.min
  range = maxc - minc
  mean = ref_count.sum.to_f / ref_count.length
  variance = ref_count.map { |x| (x - mean) ** 2 }.sum / ref_count.length
  [(range), maxc, variance]
end

best = nil
best_assignment = nil

attempts = 800
srand(12345)

attempts.times do |att|
  # deterministic re-seed per attempt
  srand(12345 + att)

  ref_count = Array.new(2 * SIDE, 0)
  round_ref_assignments = Array.new(R) { [] } # 3 teams per round, order matches ref_pairs slot_idx
  round_byes = Array.new(R) { [] }

  (0...R).each do |r|
    eligible = round_off_teams[r].dup
    raise "Round #{r}: fewer than 3 eligible teams" if eligible.length < 3

    # Rank eligible teams by current ref_count, with random tie-breaker.
    # We pick the 3 lowest-ranked teams.
    eligible.sort_by! { |t| [ref_count[t], rand] }
    chosen = eligible.first(3)

    ref_pairs.each_with_index do |pair, pi|
      t = chosen[pi]
      round_ref_assignments[r][pi] = t
      ref_count[t] += 1
    end

    chosen_set = chosen.to_h { |t| [t, true] }
    remaining = eligible.drop(3)
    remaining.each do |t|
      round_byes[r] << t
    end
  end

  # Requirement: each team must get at least one bye across all rounds.
  bye_count = Array.new(2 * SIDE, 0)
  (0...R).each do |r|
    round_byes[r].each { |t| bye_count[t] += 1 }
  end
  next if bye_count.any? { |c| c < 1 }

  # Sanity: ref slot per round is 3 teams, all byes are eligible teams not playing.
  (0...R).each do |r|
    raise "Round #{r}: ref count != 3" if round_ref_assignments[r].length != 3
    (round_ref_assignments[r] + round_byes[r]).each do |t|
      raise "Round #{r}: ref/bye includes playing team" unless round_off_teams[r].include?(t)
    end
    raise "Round #{r}: duplicate teams in refs" if round_ref_assignments[r].uniq.length != 3
  end

  begin
    validate_accounting!(round_courts, round_ref_assignments, round_byes)
  rescue StandardError
    next
  end

  sc = score_ref_counts(ref_count)

  better = false
  if best.nil?
    better = true
  else
    # Lexicographic compare: lower range first, then lower max_ref, then lower variance.
    if sc[0] < best[0]
      better = true
    elsif sc[0] == best[0] && sc[1] < best[1]
      better = true
    elsif sc[0] == best[0] && sc[1] == best[1] && sc[2] < best[2]
      better = true
    end
  end

  if better
    best = sc
    best_assignment = {
      ref_count: ref_count.dup,
      round_ref_assignments: round_ref_assignments.map(&:dup),
      round_byes: round_byes.map(&:dup),
    }
  end
end

if best_assignment.nil?
  abort "Failed to assign refs/byes."
end

# Print results as time slots.
start_minutes = 10*60
slot_len = 15

# helper to format time
fmt_time = lambda do |mins|
  h = mins / 60
  m = mins % 60
  ampm = h >= 12 ? 'PM' : 'AM'
  h12 = h % 12
  h12 = 12 if h12 == 0
  "#{h12}:#{m.to_s.rjust(2,'0')} #{ampm}"
end

(0...R).each do |r|
  t = start_minutes + r * slot_len
  puts "Round #{r+1} (#{fmt_time.call(t)} - #{fmt_time.call(t+slot_len)}):"

  # Courts (may include an empty court in 5-game rounds)
  (0...COURTS).each do |ci|
    game = round_courts[r][ci]
    if game.nil?
      puts "  Court #{ci+1}: (no game)"
    else
      puts "  Court #{ci+1}: Team #{game[0]+1} vs Team #{game[1]+1}"
    end
  end

  # Ref slots (one team each)
  round_ref = best_assignment[:round_ref_assignments][r]
  round_ref.each_with_index do |team_idx, pair_slot_idx|
    pair = ref_pairs[pair_slot_idx]
    puts "  Ref (#{pair[:label]}): Team #{team_idx+1}"
  end

  # Bye slots (remaining non-playing teams)
  byes = best_assignment[:round_byes][r].sort
  if byes.length == 1
    puts "  Bye: Team #{byes[0] + 1}"
  else
    puts "  Byes: Teams #{byes.map { |x| x + 1 }.join(', ')}"
  end
  puts ""
end

puts "Ref distribution summary:"
best_assignment[:ref_count].each_with_index do |c, ti|
  puts "  Team #{ti+1}: #{c} refs"
end
