//
//  LocalizationManager.swift
//  Moheetik
//
//  Created for Arabic localization and command handling.
//

import Foundation

/// Supported languages for the app.
enum AppLanguage: String {
    case english = "en"
    case arabic = "ar"
}

/// Controls language detection and Arabic translations.
struct LocalizationManager {
    /// Shared instance for convenience.
    static let shared = LocalizationManager()
    
    /// Current app language, refreshed via `refreshLanguage()`.
    static private(set) var currentLanguage: AppLanguage = .english
    
    /// Convenience flag for Arabic.
    static var isArabic: Bool { currentLanguage == .arabic }
    
    /// Builds the manager and sets the initial language.
    private init() {
        LocalizationManager.refreshLanguage()
    }
    
    /// Instance convenience to avoid static-call warnings from instance usage.
    func refresh(locale: Locale = .current) {
        LocalizationManager.refreshLanguage(locale: locale)
    }
    
    /// Refresh language based on system locale / preferred languages.
    /// Checks the device locale and sets Arabic or English.
    static func refreshLanguage(locale: Locale = .current) {
        let detectedCode = detectLanguageCode(locale: locale)
        currentLanguage = detectedCode == "ar" ? .arabic : .english
        
        let systemLocale = locale.identifier
        print("🌎 DEBUG: System Locale Read: \(systemLocale), Setting isArabic: \(isArabic)")
    }
    
    /// Best-effort language code detection (uses preferred languages first).
    /// Tries to find the best language code from system settings.
    private static func detectLanguageCode(locale: Locale) -> String {
        if let preferred = Locale.preferredLanguages.first {
            let loc = Locale(identifier: preferred)
            if let code = loc.language.languageCode?.identifier, !code.isEmpty {
                return code
            }
            let split = preferred.split { $0 == "_" || $0 == "-" }
            if let first = split.first, !first.isEmpty {
                return String(first)
            }
        }
        
        if let modern = locale.language.languageCode?.identifier, !modern.isEmpty {
            return modern
        }
        
        let id = locale.identifier
        let split = id.split { $0 == "_" || $0 == "-" }
        if let first = split.first, !first.isEmpty { return String(first) }
        return "en"
    }
    
    /// Arabic translations with Harakat/Tashkeel for clearer speech.
    /// Keys are the English detection IDs; values are their Arabic pronunciations.
    static let arabicDictionary: [String: String] = [

        // --- YOLOv3 Classes (Dialect) ---

        "person": "شَخْص",
        "bicycle": "دَرّاجَة",
        "car": "سَيّارَة",
        "motorbike": "دَرّاجَة ناريّة",
        "aeroplane": "طَيّارَة",
        "bus": "باص",
        "train": "قِطار",
        "truck": "شاحِنَة",
        "boat": "قارِب",
        "traffic light": "إشارة مُرور",
        "fire hydrant": "مَطَفّاة",
        "stop sign": "لَوحة قِف",
        "parking meter": "عَدّاد مَوقِف",
        "bench": "كُرسي",
        "bird": "طَيْر",
        "cat": "قِطّة",
        "dog": "كَلْب",
        "horse": "حِصان",
        "sheep": "خَروف",
        "cow": "بَقَرة",
        "elephant": "فِيل",
        "bear": "دِب",
        "zebra": "حِمار وَحْشِي",
        "giraffe": "زَرافَة",
        "backpack": "شَنْطَة ظَهْر",
        "umbrella": "مِظلّة",
        "handbag": "شَنْطَة",
        "tie": "رَبْطَة",
        "suitcase": "حَقيبَة",
        "frisbee": "قُرص طايِر",
        "skis": "مِزْلَجات",
        "snowboard": "لَوْح تَزَلّج",
        "sports ball": "كُرَة",
        "kite": "طَيّارَة ورَق",
        "baseball bat": "مِضْرَب",
        "baseball glove": "قُفّاز",
        "skateboard": "سْكِيت بورد",
        "surfboard": "لَوْح أَمواج",
        "tennis racket": "مِضْرَب تِنِس",
        "bottle": "قَارورَة",
        "wine glass": "كَأس",
        "cup": "كوب",
        "fork": "شَوْكَة",
        "knife": "سِكّين",
        "spoon": "مِلْعَقَة",
        "bowl": "صَحْن عَميق",
        "banana": "مَوز",
        "apple": "تُفّاح",
        "sandwich": "سَندويش",
        "orange": "بُرتُقال",
        "broccoli": "بروكلي",
        "carrot": "جَزر",
        "hot dog": "هوت دوغ",
        "pizza": "بِيتزا",
        "donut": "دونَت",
        "cake": "كَيْك",
        "chair": "كُرسي",
        "sofa": "كَنَبَة",
        "pottedplant": "نَبْتَة",
        "bed": "سَرِير",
        "diningtable": "طاوِلَة أَكل",
        "toilet": "دَوْرَة مِيَاه",
        "tvmonitor": "شاشَة",
        "laptop": "لاب توب",
        "mouse": "ماوس",
        "remote": "رِيموت",
        "keyboard": "كِيبورد",
        "cell phone": "جَوّال",
        "microwave": "مِيكْرُويف",
        "oven": "فُرْن",
        "toaster": "مُحَمِّص",
        "sink": "مَغْسَل",
        "refrigerator": "ثَلّاجَة",
        "book": "كِتاب",
        "clock": "ساعَة",
        "vase": "مِزْهَرِيّة",
        "scissors": "مِقَص",
        "teddy bear": "دُب لُعْبَة",
        "hair drier": "سِشْوار",
        "toothbrush": "فُرْشَة أَسْنان",

        // --- Navigation Classes (Dialect Added) ---

        "door": "بَاب",
        "stairs": "دَرَج",
        "elevator": "مِصْعَد",
        "elevator_button": "زِر المِصْعَد",
        "exit": "مَخْرَج",
        "entrance": "مَدْخَل",
        "handrail": "دَرَابْزِين",
        "ramp": "مُنْحَدَر",
        "crossing": "مَمَر مُشَاة",
        "sidewalk": "رَصِيف",

        // --- Aliases to cover voice synonyms ---

        "tv": "شاشَة",
        "phone": "جَوّال",
        "mobile": "جَوّال",
        "table": "طاوِلَة أَكل",
        "plant": "نَبْتَة"

    ]
    
    /// Allows manual override of the language.
    static func setLanguage(from locale: Locale = .current) {
        refreshLanguage(locale: locale)
    }
    
    /// Converts an English object ID to the current language text.
    static func localizedName(for englishID: String) -> String {
        switch currentLanguage {
        case .english:
            return englishID
        case .arabic:
            return arabicDictionary[englishID.lowercased()] ?? englishID
        }
    }
    
    /// Checks if a string has Arabic letters.
    static func containsArabicCharacters(_ text: String) -> Bool {
        return text.range(of: "\\p{Arabic}", options: .regularExpression) != nil
    }
    
    /// Normalizes Arabic text by removing diacritics and variants.
    static func cleanArabic(_ text: String) -> String {
        let harakatPattern = "[\\u0610-\\u061A\\u064B-\\u065F\\u0670]"
        var cleaned = text.replacingOccurrences(of: harakatPattern, with: "", options: .regularExpression)
            .lowercased()
        
        cleaned = cleaned.replacingOccurrences(of: "أ", with: "ا")
        cleaned = cleaned.replacingOccurrences(of: "إ", with: "ا")
        cleaned = cleaned.replacingOccurrences(of: "آ", with: "ا")
        cleaned = cleaned.replacingOccurrences(of: "ٱ", with: "ا")
        cleaned = cleaned.replacingOccurrences(of: "ة", with: "ه")
        cleaned = cleaned.replacingOccurrences(of: "ى", with: "ي")
        
        if cleaned.hasPrefix("ال") {
            cleaned = String(cleaned.dropFirst(2))
        }
        
        cleaned = cleaned.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Finds the English ID for a spoken Arabic command.
    static func matchArabicCommand(_ text: String) -> String? {
        let normalizedInput = cleanArabic(text)
        
        for (english, arabicValue) in arabicDictionary {
            let normalizedArabic = cleanArabic(arabicValue)
            if normalizedInput.contains(normalizedArabic) {
                return english
            }
        }
        return nil
    }
    
    /// Pulls a spoken number (1-3) from Arabic text.
    static func extractNumber(from text: String) -> Int? {
        let normalized = cleanArabic(text)
        let arabicWords: [String: Int] = [
            "واحد": 1, "١": 1, "1": 1,
            "اثنان": 2, "اثنين": 2, "٢": 2, "2": 2,
            "ثلاثة": 3, "٣": 3, "3": 3
        ]
        for (word, number) in arabicWords {
            if normalized.contains(word) { return number }
        }
        if let digit = normalized.first(where: { $0.isNumber }), let value = Int(String(digit)) {
            return value
        }
        return nil
    }
    
    /// Locale used for speech synthesis/recognition.
    static var speechLocale: Locale {
        currentLanguage == .arabic ? Locale(identifier: "ar-SA") : Locale(identifier: "en-US")
    }
    
    /// Localize any outgoing spoken/display text by replacing known object IDs with Arabic equivalents.
    static func localizeForSpeech(_ text: String) -> String {
        guard isArabic else { return text }
        var output = text
        // Replace longer keys first to avoid partial overlaps.
        let sortedKeys = arabicDictionary.keys.sorted { $0.count > $1.count }
        for key in sortedKeys {
            let localized = arabicDictionary[key] ?? key
            output = output.replacingOccurrences(of: key, with: localized, options: .caseInsensitive)
        }
        return output
    }
    
    /// Localize status/general phrases, then apply object-name localization for speech/UI.
    /// Localizes status text then object names for speech/display.
    static func localizeOutput(_ text: String) -> String {
        let status = localizeStatus(text)
        let distance = localizeDistances(status)
        var output = localizeForSpeech(distance)
        output = output.replacingOccurrences(of: "...", with: "")
        output = output.replacingOccurrences(of: "..", with: "")
        return output
    }
    
    /// Map common UI/status English phrases to Arabic.
    /// Maps common status phrases to Arabic.
    static func localizeStatus(_ text: String) -> String {
        guard isArabic else { return text }
        var output = text
        for (english, arabic) in statusTranslations {
            output = output.replacingOccurrences(of: english, with: arabic, options: .caseInsensitive)
        }
        return output
    }
    
    private static let statusTranslations: [String: String] = [
        "Starting Hold steady": "جَارٍ البَدْءُ... اِثْبُتْ مَكَانَكَ",
        "Starting": "جَارٍ البَدْءُ",
        "Hold steady": "اِثْبُتْ مَكَانَكَ",
        "Finished": "اِنْتَهَى",
        "Start Scanning": "بَدْءُ المَسْحِ",
        "Stop Scanning": "إِيقَافُ المَسْحِ",
        "Voice Command": "أَمْرٌ صَوْتِيّ",
        "Stop Listening": "إِيقَافُ الاِسْتِمَاعِ",
        "Searching for": "جَارٍ البَحْثُ عَنْ",
        "Looking for:": "جَارٍ البَحْثُ عَنْ:",
        "Locked onto": "تَمَّ التَّثْبِيتُ عَلَى",
        "You have arrived at": "لَقَدْ وَصَلْتَ إِلَى",
        "Scanning finished.": "اِنْتَهَى المَسْحُ",
        "Target lost": "فُقِدَ الهَدَفُ",
        "Target lost. Move back.": "فُقِدَ الهَدَفُ. تَرَاجَعْ.",
        "Could not understand. Try 'Chair 1'.": "لَمْ أَفْهَمْ. جَرِّبْ 'كُرْسِيّ 1'.",
        "Found": "تَمَّ العُثُورُ عَلَى",
        "Please turn around to find": "يُرْجَى الدَّوَرَانُ لِلعُثُورِ عَلَى",
        "Turn left": "اِنْعَطِفْ يَسَارًا",
        "Turn right": "اِنْعَطِفْ يَمِينًا",
        "Move forward": "تَقَدَّمْ إِلَى الأَمَامِ",
        "Target is behind you. Turn around.": "الهَدَفُ خَلْفَكَ. اِسْتَدِرْ."
    ]
    
    /// Localize distance phrases like "1.5 meters away"
    /// Localizes distance phrases and replaces decimal dot with Arabic speech.
    private static func localizeDistances(_ text: String) -> String {
        guard isArabic else { return text }
        var output = text
        
        // Almost there
        output = output.replacingOccurrences(of: "Almost there", with: "اقتربت من الهدف", options: .caseInsensitive)
        
        // 1 meter away (singular)
        output = output.replacingOccurrences(of: "1 meter away", with: "متر واحد بعيداً", options: .caseInsensitive)
        
        // n meters away (numeric)
        if let range = output.range(of: #"([0-9]+(\.[0-9]+)?)\s+meters away"#, options: .regularExpression) {
            let number = String(output[range]).components(separatedBy: " ").first ?? ""
            let spokenNumber = number.replacingOccurrences(of: ".", with: ",")
            output.replaceSubrange(range, with: "\(spokenNumber) متر بعيداً")
        }
        
        // generic meter away
        output = output.replacingOccurrences(of: "meters away", with: "متر بعيداً", options: .caseInsensitive)
        output = output.replacingOccurrences(of: "meter away", with: "متر بعيداً", options: .caseInsensitive)
        return output
    }
}

