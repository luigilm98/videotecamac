import Foundation

enum CatalogClassification {
    private static let genreAliases: [String: [String]] = {
        let groups: [(String, [String])] = [
            ("Drammatico", ["Dramma", "Drama", "film drammatico", "melodramma"]),
            ("Commedia", ["Comedy", "film commedia", "film commedia nera", "commedia all'italiana", "buddy film", "Screwball comedy", "film satirico", "Satirico"]),
            ("Sentimentale", ["Romance", "film sentimentale"]),
            ("Storico", ["Storia", "History", "film storico"]),
            ("Poliziesco", ["Crime", "film di gangster", "Gangster"]),
            ("Giallo", ["Mistero", "Mystery", "film giallo", "film del mistero"]),
            ("Thriller", ["film thriller", "political thriller film", "psychological thriller film"]),
            ("Fantascienza", ["Science Fiction", "film di fantascienza", "arthouse science fiction film", "film distopico", "time-travel film", "cyberpunk", "space adventure film"]),
            ("Fantasy", ["film fantasy"]),
            ("Avventura", ["Adventure", "film d'avventura"]),
            ("Azione", ["Action", "film d'azione", "film di supereroi"]),
            ("Guerra", ["War", "cinema di guerra"]),
            ("Biografico", ["Biography", "film biografico"]),
            ("Documentario", ["Documentary"]),
            ("Noir", ["film noir", "neo-noir"]),
            ("Spionaggio", ["film di spionaggio"]),
            ("Western", ["western all'italiana"]),
            ("Horror", ["film dell'orrore"]),
            ("Animazione", ["Animation"]),
            ("Famiglia", ["Family", "film per bambini", "Famiglie"]),
            ("Musica", ["Music"]),
            ("Film TV", ["TV Movie"])
        ]
        var aliases: [String: [String]] = [:]
        for (genre, variants) in groups {
            for variant in [genre] + variants {
                aliases[ManualMovieCorrections.normalized(variant)] = [genre]
            }
        }
        aliases["commedia drammatica"] = ["Commedia", "Drammatico"]
        aliases["tragicommedia"] = ["Commedia", "Drammatico"]
        aliases["commedia romantica"] = ["Commedia", "Sentimentale"]
        aliases["romantic comedy film"] = ["Commedia", "Sentimentale"]
        aliases["thriller poliziesco"] = ["Thriller", "Poliziesco"]
        aliases["docu drama"] = ["Drammatico"]
        return aliases
    }()

    static func genres(from sources: [String], custom: [String] = []) -> [String] {
        Movie.unique(sources.flatMap { genreAliases[ManualMovieCorrections.normalized($0)] ?? [] } +
            custom.flatMap { genreAliases[ManualMovieCorrections.normalized($0)] ?? [$0] })
    }

    static func personKey(_ name: String) -> String {
        ManualMovieCorrections.normalized(name)
    }

    static func people(_ credits: [String]) -> [String] {
        let placeholders: Set<String> = ["", "sconosciuto", "sconosciuta", "unknown", "n a", "serie tv", "cast", "various", "vari", "aa vv"]
        var seen = Set<String>()
        return credits.flatMap {
            $0.replacingOccurrences(of: " & ", with: ",")
                .components(separatedBy: CharacterSet(charactersIn: ",;/"))
        }.compactMap { credit in
            let name = credit.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let key = personKey(name)
            guard !placeholders.contains(key), seen.insert(key).inserted else { return nil }
            return name
        }
    }
}

struct CatalogFacet: Identifiable {
    let id: String
    let name: String
    let itemIDs: Set<String>

    var count: Int { itemIDs.count }

    static func index(_ items: [LibraryItem], values: KeyPath<LibraryItem, [String]>, key: (String) -> String) -> [Self] {
        var names: [String: String] = [:]
        var memberships: [String: Set<String>] = [:]
        for item in items {
            for name in item[keyPath: values] {
                let id = key(name)
                if names[id] == nil { names[id] = name }
                memberships[id, default: []].insert(item.id)
            }
        }
        return names.compactMap { id, name in
            memberships[id].map { Self(id: id, name: name, itemIDs: $0) }
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
