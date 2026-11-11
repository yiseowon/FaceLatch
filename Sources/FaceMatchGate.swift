struct FaceMatchGate {
    private var consecutiveMatches = 0

    mutating func observe(score: Float?) -> Bool {
        guard let score, score.isFinite, score >= 0.48 else {
            consecutiveMatches = 0
            return false
        }
        consecutiveMatches += 1
        return consecutiveMatches >= 3
    }
}
