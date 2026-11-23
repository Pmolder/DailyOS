import Foundation

// MARK: - 80+ Curated iOS 17+ Habit SF Symbol Library with Categories & Search Keywords

enum HabitIconCategory: String, CaseIterable, Identifiable {
    case all = "All"
    case fitness = "Fitness"
    case hydration = "Hydration"
    case mindfulness = "Mindfulness"
    case learning = "Learning"
    case deepWork = "Deep Work"
    case quit = "Quit"
    case outdoors = "Outdoors"
    case dailyLife = "Daily Life"

    var id: String { rawValue }
}

struct HabitIconEntry: Identifiable, Hashable {
    var id: String { symbol }
    let symbol: String
    let category: HabitIconCategory
    let keywords: [String]

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if symbol.lowercased().contains(q) { return true }
        if category.rawValue.lowercased().contains(q) { return true }
        return keywords.contains { $0.lowercased().contains(q) }
    }
}

enum HabitIconLibrary {
    static let allIcons: [HabitIconEntry] = [
        // 1. Fitness & Strength (12)
        HabitIconEntry(symbol: "figure.run", category: .fitness, keywords: ["run", "running", "jog", "cardio", "marathon", "sprint"]),
        HabitIconEntry(symbol: "dumbbell.fill", category: .fitness, keywords: ["gym", "weights", "lift", "lifting", "strength", "workout"]),
        HabitIconEntry(symbol: "figure.strengthtraining.traditional", category: .fitness, keywords: ["workout", "squats", "exercise", "training", "barbell"]),
        HabitIconEntry(symbol: "figure.walk", category: .fitness, keywords: ["walk", "steps", "stroll", "cardio", "pedometer"]),
        HabitIconEntry(symbol: "bicycle", category: .fitness, keywords: ["bike", "cycling", "ride", "spin"]),
        HabitIconEntry(symbol: "figure.pool.swim", category: .fitness, keywords: ["swim", "swimming", "pool", "laps"]),
        HabitIconEntry(symbol: "figure.core.training", category: .fitness, keywords: ["core", "abs", "plank", "pilates", "stretch"]),
        HabitIconEntry(symbol: "figure.martial.arts", category: .fitness, keywords: ["boxing", "mma", "karate", "martial", "kickboxing"]),
        HabitIconEntry(symbol: "flame.fill", category: .fitness, keywords: ["burn", "calories", "streak", "fire", "hiit"]),
        HabitIconEntry(symbol: "bolt.heart.fill", category: .fitness, keywords: ["heart", "cardio", "pulse", "energy", "fitness"]),
        HabitIconEntry(symbol: "sportscourt.fill", category: .fitness, keywords: ["sports", "basketball", "tennis", "court", "game"]),
        HabitIconEntry(symbol: "figure.hiking", category: .fitness, keywords: ["hike", "hiking", "trail", "climb"]),

        // 2. Hydration & Nutrition (10)
        HabitIconEntry(symbol: "drop.fill", category: .hydration, keywords: ["water", "drink", "hydrate", "hydration", "liquid"]),
        HabitIconEntry(symbol: "cup.and.saucer.fill", category: .hydration, keywords: ["coffee", "tea", "espresso", "caffeine", "morning"]),
        HabitIconEntry(symbol: "waterbottle.fill", category: .hydration, keywords: ["bottle", "water", "electrolytes", "hydrate", "flask"]),
        HabitIconEntry(symbol: "fork.knife", category: .hydration, keywords: ["eat", "meal", "food", "diet", "cook", "protein", "fasting"]),
        HabitIconEntry(symbol: "carrot.fill", category: .hydration, keywords: ["veggies", "vegetables", "healthy", "nutrition", "salad"]),
        HabitIconEntry(symbol: "leaf.fill", category: .hydration, keywords: ["vegan", "greens", "organic", "plant", "nature", "healthy"]),
        HabitIconEntry(symbol: "pills.fill", category: .hydration, keywords: ["vitamins", "supplements", "creatine", "medicine", "meds"]),
        HabitIconEntry(symbol: "heart.text.square.fill", category: .hydration, keywords: ["health", "track", "macros", "calories", "log"]),
        HabitIconEntry(symbol: "mug.fill", category: .hydration, keywords: ["tea", "matcha", "coffee", "warm", "drink"]),
        HabitIconEntry(symbol: "takeoutbag.and.cup.and.straw.fill", category: .hydration, keywords: ["takeout", "fastfood", "delivery", "junk", "mealprep"]),

        // 3. Mindfulness & Sleep (10)
        HabitIconEntry(symbol: "brain.head.profile", category: .mindfulness, keywords: ["mind", "mental", "focus", "think", "meditate", "brain"]),
        HabitIconEntry(symbol: "sparkles", category: .mindfulness, keywords: ["gratitude", "clarity", "clean", "magic", "reflect"]),
        HabitIconEntry(symbol: "moon.stars.fill", category: .mindfulness, keywords: ["sleep", "night", "bedtime", "rest", "winddown"]),
        HabitIconEntry(symbol: "bed.double.fill", category: .mindfulness, keywords: ["bed", "sleep", "8hours", "nap", "makebed"]),
        HabitIconEntry(symbol: "sun.max.fill", category: .mindfulness, keywords: ["sunlight", "morning", "wake", "vitamin d", "daylight"]),
        HabitIconEntry(symbol: "lungs.fill", category: .mindfulness, keywords: ["breathe", "breathing", "breathwork", "wim hof", "calm"]),
        HabitIconEntry(symbol: "wind", category: .mindfulness, keywords: ["air", "calm", "breathe", "fresh", "relax"]),
        HabitIconEntry(symbol: "eye.fill", category: .mindfulness, keywords: ["visualize", "vision", "eyes", "screen break", "awareness"]),
        HabitIconEntry(symbol: "heart.fill", category: .mindfulness, keywords: ["love", "kindness", "gratitude", "selfcare", "health"]),
        HabitIconEntry(symbol: "figure.mind.and.body", category: .mindfulness, keywords: ["meditate", "meditation", "yoga", "zen", "mindfulness"]),

        // 4. Learning & Reading (10)
        HabitIconEntry(symbol: "book.fill", category: .learning, keywords: ["read", "reading", "book", "pages", "study"]),
        HabitIconEntry(symbol: "books.vertical.fill", category: .learning, keywords: ["library", "books", "reading", "literature"]),
        HabitIconEntry(symbol: "text.book.closed.fill", category: .learning, keywords: ["journal", "diary", "notes", "reading", "textbook"]),
        HabitIconEntry(symbol: "graduationcap.fill", category: .learning, keywords: ["study", "course", "university", "school", "learn", "exam"]),
        HabitIconEntry(symbol: "newspaper.fill", category: .learning, keywords: ["news", "articles", "read", "current events"]),
        HabitIconEntry(symbol: "character.book.closed.fill", category: .learning, keywords: ["language", "vocab", "spanish", "french", "estonian", "duolingo"]),
        HabitIconEntry(symbol: "headphones", category: .learning, keywords: ["podcast", "audiobook", "listen", "audio", "music"]),
        HabitIconEntry(symbol: "lightbulb.fill", category: .learning, keywords: ["idea", "learn", "brainstorm", "creativity", "think"]),
        HabitIconEntry(symbol: "puzzlepiece.extension.fill", category: .learning, keywords: ["chess", "puzzle", "logic", "brain", "problem"]),
        HabitIconEntry(symbol: "globe.europe.africa.fill", category: .learning, keywords: ["world", "language", "geography", "travel", "global"]),

        // 5. Deep Work & Tech (10)
        HabitIconEntry(symbol: "laptopcomputer", category: .deepWork, keywords: ["code", "coding", "work", "deep work", "laptop", "build"]),
        HabitIconEntry(symbol: "terminal.fill", category: .deepWork, keywords: ["programming", "dev", "terminal", "cli", "software", "code"]),
        HabitIconEntry(symbol: "desktopcomputer", category: .deepWork, keywords: ["desk", "work", "computer", "studio", "focus"]),
        HabitIconEntry(symbol: "timer", category: .deepWork, keywords: ["pomodoro", "timer", "deep work", "sprint", "focus"]),
        HabitIconEntry(symbol: "target", category: .deepWork, keywords: ["goal", "priority", "focus", "aim", "hit"]),
        HabitIconEntry(symbol: "checkmark.seal.fill", category: .deepWork, keywords: ["done", "complete", "review", "plan", "verify"]),
        HabitIconEntry(symbol: "chart.line.uptrend.xyaxis", category: .deepWork, keywords: ["growth", "invest", "finance", "business", "metrics"]),
        HabitIconEntry(symbol: "folder.fill", category: .deepWork, keywords: ["organize", "files", "admin", "clean", "project"]),
        HabitIconEntry(symbol: "pencil.and.outline", category: .deepWork, keywords: ["write", "writing", "journal", "essay", "draft", "blog"]),
        HabitIconEntry(symbol: "keyboard.fill", category: .deepWork, keywords: ["typing", "writing", "code", "work"]),

        // 6. Quit & Discipline (10)
        HabitIconEntry(symbol: "hand.raised.fill", category: .quit, keywords: ["stop", "quit", "no", "abstain", "discipline"]),
        HabitIconEntry(symbol: "shield.checkered", category: .quit, keywords: ["protect", "guard", "clean", "sober", "discipline"]),
        HabitIconEntry(symbol: "xmark.octagon.fill", category: .quit, keywords: ["avoid", "stop", "quit", "no", "ban"]),
        HabitIconEntry(symbol: "iphone.slash", category: .quit, keywords: ["no phone", "dopamine", "detox", "doomscroll", "social media"]),
        HabitIconEntry(symbol: "smoke.fill", category: .quit, keywords: ["smoking", "vape", "nicotine", "quit", "cigarettes"]),
        HabitIconEntry(symbol: "wineglass.fill", category: .quit, keywords: ["alcohol", "sober", "drinks", "quit", "wine"]),
        HabitIconEntry(symbol: "gamecontroller.fill", category: .quit, keywords: ["gaming", "games", "quit", "limit", "play"]),
        HabitIconEntry(symbol: "tv.slash.fill", category: .quit, keywords: ["no tv", "netflix", "youtube", "screen", "detox"]),
        HabitIconEntry(symbol: "lock.shield.fill", category: .quit, keywords: ["lock", "discipline", "guard", "willpower"]),
        HabitIconEntry(symbol: "bolt.slash.fill", category: .quit, keywords: ["no caffeine", "energy drink", "sugar", "detox"]),

        // 7. Outdoors & Morning (8)
        HabitIconEntry(symbol: "sunrise.fill", category: .outdoors, keywords: ["morning", "early", "wake", "dawn", "sunrise"]),
        HabitIconEntry(symbol: "sunset.fill", category: .outdoors, keywords: ["evening", "dusk", "winddown", "sunset"]),
        HabitIconEntry(symbol: "tree.fill", category: .outdoors, keywords: ["nature", "park", "forest", "outside", "walk"]),
        HabitIconEntry(symbol: "mountain.2.fill", category: .outdoors, keywords: ["mountain", "outdoor", "adventure", "climb"]),
        HabitIconEntry(symbol: "cloud.sun.fill", category: .outdoors, keywords: ["outside", "weather", "fresh air", "morning"]),
        HabitIconEntry(symbol: "thermometer.sun.fill", category: .outdoors, keywords: ["sauna", "cold plunge", "heat", "temperature"]),
        HabitIconEntry(symbol: "figure.cooldown", category: .outdoors, keywords: ["stretch", "mobility", "recovery", "cooldown", "flexibility"]),
        HabitIconEntry(symbol: "shoeprints.fill", category: .outdoors, keywords: ["steps", "walk", "outside", "10k"]),

        // 8. Daily Life & Creative (14)
        HabitIconEntry(symbol: "house.fill", category: .dailyLife, keywords: ["home", "clean", "tidy", "chores", "room"]),
        HabitIconEntry(symbol: "shower.fill", category: .dailyLife, keywords: ["cold shower", "shower", "hygiene", "skin", "wash"]),
        HabitIconEntry(symbol: "banknote.fill", category: .dailyLife, keywords: ["money", "save", "budget", "finance", "no spend"]),
        HabitIconEntry(symbol: "music.note", category: .dailyLife, keywords: ["music", "piano", "practice", "song", "sing"]),
        HabitIconEntry(symbol: "guitars.fill", category: .dailyLife, keywords: ["guitar", "instrument", "music", "practice"]),
        HabitIconEntry(symbol: "paintbrush.fill", category: .dailyLife, keywords: ["art", "draw", "paint", "design", "create"]),
        HabitIconEntry(symbol: "camera.fill", category: .dailyLife, keywords: ["photo", "photography", "video", "create"]),
        HabitIconEntry(symbol: "envelope.fill", category: .dailyLife, keywords: ["inbox", "email", "inbox zero", "messages"]),
        HabitIconEntry(symbol: "clock.fill", category: .dailyLife, keywords: ["time", "schedule", "on time", "punctual"]),
        HabitIconEntry(symbol: "star.fill", category: .dailyLife, keywords: ["highlight", "win", "goal", "priority", "star"]),
        HabitIconEntry(symbol: "briefcase.fill", category: .dailyLife, keywords: ["career", "work", "job", "business"]),
        HabitIconEntry(symbol: "calendar", category: .dailyLife, keywords: ["plan", "schedule", "review", "calendar"]),
        HabitIconEntry(symbol: "pawprint.fill", category: .dailyLife, keywords: ["dog", "pet", "walk", "cat"]),
        HabitIconEntry(symbol: "airplane", category: .dailyLife, keywords: ["travel", "trip", "flight", "plan"])
    ]

    static func filtered(category: HabitIconCategory, query: String) -> [HabitIconEntry] {
        allIcons.filter { entry in
            let catMatches = (category == .all) || (entry.category == category)
            return catMatches && entry.matches(query)
        }
    }
}
