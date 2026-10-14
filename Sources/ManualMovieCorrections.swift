import Foundation

struct ParsedMovieInfo {
    var title: String
    var director: String
    var year: Int?
    var actors: [String]
    var inferredGenres: [String]
}

private struct ManualMovieCorrection {
    let contains: [String]
    let title: String?
    let director: String?
    let year: Int?
    let actors: [String]?
    let genres: [String]?

    func matches(titleKey: String, fileKey: String, pathKey: String) -> Bool {
        contains.allSatisfy { token in
            let key = ManualMovieCorrections.normalized(token)
            return phrase(key, isIn: titleKey) || phrase(key, isIn: fileKey) || phrase(key, isIn: pathKey)
        }
    }

    private func phrase(_ needle: String, isIn haystack: String) -> Bool {
        guard !needle.isEmpty else { return false }
        return " \(haystack) ".contains(" \(needle) ")
    }
}

enum ManualMovieCorrections {
    static func completion(for fileURL: URL, title: String) -> ParsedMovieInfo? {
        let titleKey = normalized(title)
        let fileKey = normalized(fileURL.deletingPathExtension().lastPathComponent)
        let pathKey = normalized(fileURL.path)

        guard let correction = corrections.first(where: { $0.matches(titleKey: titleKey, fileKey: fileKey, pathKey: pathKey) }) else {
            return nil
        }

        return ParsedMovieInfo(
            title: correction.title ?? title,
            director: correction.director ?? "Sconosciuto",
            year: correction.year,
            actors: correction.actors ?? [],
            inferredGenres: correction.genres ?? []
        )
    }

    static func apply(
        fileURL: URL,
        title: String,
        director: String,
        year: Int?,
        actors: [String],
        inferredGenres: [String]
    ) -> ParsedMovieInfo {
        let titleKey = normalized(title)
        let fileKey = normalized(fileURL.deletingPathExtension().lastPathComponent)
        let pathKey = normalized(fileURL.path)

        guard let correction = corrections.first(where: { $0.matches(titleKey: titleKey, fileKey: fileKey, pathKey: pathKey) }) else {
            return ParsedMovieInfo(title: title, director: director, year: year, actors: actors, inferredGenres: inferredGenres)
        }

        return ParsedMovieInfo(
            title: correction.title ?? title,
            director: correction.director ?? director,
            year: correction.year ?? year,
            actors: correction.actors ?? actors,
            inferredGenres: Movie.unique((correction.genres ?? []) + inferredGenres)
        )
    }

    static func normalized(_ value: String) -> String {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        var cleaned = ""
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned.split(separator: " ").joined(separator: " ")
    }

    private static let corrections: [ManualMovieCorrection] = [
        ManualMovieCorrection(
            contains: ["la bocca del lupo"],
            title: "La bocca del lupo",
            director: "Pietro Marcello",
            year: 2009,
            actors: ["Enzo Motta", "Mary Monaco"],
            genres: ["Documentario"]
        ),
        ManualMovieCorrection(
            contains: ["berlinguer", "grande ambizione"],
            title: "Berlinguer - La grande ambizione",
            director: "Andrea Segre",
            year: 2024,
            actors: ["Elio Germano", "Stefano Abbati"],
            genres: ["Biografico", "Storico"]
        ),
        ManualMovieCorrection(
            contains: ["rita la zanzara"],
            title: "Rita la zanzara",
            director: "Lina Wertmuller",
            year: 1966,
            actors: ["Rita Pavone", "Giancarlo Giannini"],
            genres: ["Commedia", "Musicale"]
        ),
        ManualMovieCorrection(
            contains: ["toto truffa"],
            title: "Totòtruffa '62",
            director: "Camillo Mastrocinque",
            year: 1961,
            actors: ["Totò", "Nino Taranto"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["il mondo nuovo"],
            title: "Il mondo nuovo",
            director: "Ettore Scola",
            year: 1982,
            actors: ["Marcello Mastroianni", "Hanna Schygulla"],
            genres: ["Storico"]
        ),
        ManualMovieCorrection(
            contains: ["dramma della gelosia"],
            title: "Dramma della gelosia - Tutti i particolari in cronaca",
            director: "Ettore Scola",
            year: 1970,
            actors: ["Marcello Mastroianni", "Monica Vitti", "Giancarlo Giannini"],
            genres: ["Commedia", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["trevico", "fiat"],
            title: "Trevico-Torino - Viaggio nel Fiat-Nam",
            director: "Ettore Scola",
            year: 1973,
            actors: ["Paolo Turco", "Vittorio Gassman"],
            genres: ["Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["la grande partita"],
            title: "La grande partita",
            director: "Edward Zwick",
            year: 2015,
            actors: ["Tobey Maguire", "Liev Schreiber", "Peter Sarsgaard"],
            genres: ["Biografico", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["amici miei", "atto ii"],
            title: "Amici miei - Atto II",
            director: "Mario Monicelli",
            year: 1982,
            actors: ["Ugo Tognazzi", "Gastone Moschin", "Philippe Noiret"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["amici miei", "atto 2"],
            title: "Amici miei - Atto II",
            director: "Mario Monicelli",
            year: 1982,
            actors: ["Ugo Tognazzi", "Gastone Moschin", "Philippe Noiret"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["amici miei", "atto iii"],
            title: "Amici miei - Atto III",
            director: "Nanni Loy",
            year: 1985,
            actors: ["Ugo Tognazzi", "Gastone Moschin", "Renzo Montagnani"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["amici miei", "atto 3"],
            title: "Amici miei - Atto III",
            director: "Nanni Loy",
            year: 1985,
            actors: ["Ugo Tognazzi", "Gastone Moschin", "Renzo Montagnani"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["amici miei"],
            title: "Amici miei",
            director: "Mario Monicelli",
            year: 1975,
            actors: ["Ugo Tognazzi", "Gastone Moschin", "Philippe Noiret"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["sissignore"],
            title: "Sissignore",
            director: "Ugo Tognazzi",
            year: 1968,
            actors: ["Ugo Tognazzi", "Maria Grazia Buccella"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["il vizietto"],
            title: "Il vizietto",
            director: "Edouard Molinaro",
            year: 1978,
            actors: ["Ugo Tognazzi", "Michel Serrault"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["la chiave", "1983"],
            title: "La chiave",
            director: "Tinto Brass",
            year: 1983,
            actors: ["Stefania Sandrelli", "Frank Finlay"],
            genres: ["Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["cattivi pensieri"],
            title: "Cattivi pensieri",
            director: "Ugo Tognazzi",
            year: 1976,
            actors: ["Ugo Tognazzi", "Edwige Fenech"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["dov e la liberta"],
            title: "Dov'è la libertà...?",
            director: "Roberto Rossellini",
            year: 1954,
            actors: ["Totò", "Vera Molnar", "Nyta Dover", "Franca Faldini", "Leopoldo Trieste"],
            genres: ["Commedia", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["f f s s", "posillipo"],
            title: "\"FF.SS.\" - Cioè: \"...che mi hai portato a fare sopra a Posillipo se non mi vuoi più bene?\"",
            director: "Renzo Arbore",
            year: 1983,
            actors: ["Renzo Arbore", "Pietra Montecorvino"],
            genres: ["Commedia", "Musicale"]
        ),
        ManualMovieCorrection(
            contains: ["la vita agra"],
            title: "La vita agra",
            director: "Carlo Lizzani",
            year: 1964,
            actors: ["Ugo Tognazzi", "Giovanna Ralli"],
            genres: ["Commedia", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["pane e cioccolata"],
            title: "Pane e cioccolata",
            director: "Franco Brusati",
            year: 1974,
            actors: ["Nino Manfredi", "Johnny Dorelli"],
            genres: ["Commedia", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["il nostro agente all avana"],
            title: "Il nostro agente all'Avana",
            director: "Carol Reed",
            year: 1959,
            actors: ["Alec Guinness", "Burl Ives"],
            genres: ["Commedia", "Spionaggio"]
        ),
        ManualMovieCorrection(
            contains: ["piccolo cesare"],
            title: "Piccolo Cesare",
            director: "Mervyn LeRoy",
            year: 1931,
            actors: ["Edward G. Robinson", "Douglas Fairbanks Jr."],
            genres: ["Gangster", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["il giorno della civetta"],
            title: "Il giorno della civetta",
            director: "Damiano Damiani",
            year: 1968,
            actors: ["Franco Nero", "Claudia Cardinale"],
            genres: ["Drammatico", "Noir"]
        ),
        ManualMovieCorrection(
            contains: ["guardie", "ladri", "toto"],
            title: "Guardie e ladri",
            director: "Mario Monicelli, Steno",
            year: 1951,
            actors: ["Totò", "Aldo Fabrizi"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["pi greco", "teorema"],
            title: "Pi - Il teorema del delirio",
            director: "Darren Aronofsky",
            year: 1998,
            actors: ["Sean Gullette", "Mark Margolis"],
            genres: ["Thriller", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["metalmeccanico", "parrucchiera"],
            title: "Metalmeccanico e parrucchiera in un turbine di sesso e politica",
            director: "Lina Wertmuller",
            year: 1996,
            actors: ["Tullio Solenghi", "Veronica Pivetti"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["il caso mattei"],
            title: "Il caso Mattei",
            director: "Francesco Rosi",
            year: 1972,
            actors: ["Gian Maria Volonte", "Luigi Squarzina"],
            genres: ["Biografico", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["quinto potere", "network"],
            title: "Quinto potere",
            director: "Sidney Lumet",
            year: 1976,
            actors: ["Faye Dunaway", "William Holden", "Peter Finch"],
            genres: ["Drammatico", "Satirico"]
        ),
        ManualMovieCorrection(
            contains: ["mediterraneo"],
            title: "Mediterraneo",
            director: "Gabriele Salvatores",
            year: 1991,
            actors: ["Diego Abatantuono", "Claudio Bigagli"],
            genres: ["Commedia", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["operazione diabolica"],
            title: "Operazione diabolica",
            director: "John Frankenheimer",
            year: 1966,
            actors: ["Rock Hudson", "Salome Jens"],
            genres: ["Fantascienza", "Thriller"]
        ),
        ManualMovieCorrection(
            contains: ["ape regina"],
            title: "Una storia moderna - L'ape regina",
            director: "Marco Ferreri",
            year: 1963,
            actors: ["Ugo Tognazzi", "Marina Vlady"],
            genres: ["Commedia", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["sua eccellenza", "mangiare"],
            title: "Sua Eccellenza si fermò a mangiare",
            director: "Mario Mattoli",
            year: 1961,
            actors: ["Totò", "Ugo Tognazzi"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["permette", "rocco papaleo"],
            title: "Permette? Rocco Papaleo",
            director: "Ettore Scola",
            year: 1971,
            actors: ["Marcello Mastroianni", "Lauren Hutton"],
            genres: ["Commedia", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["film d amore", "anarchia"],
            title: "Film d'amore e d'anarchia",
            director: "Lina Wertmuller",
            year: 1973,
            actors: ["Giancarlo Giannini", "Mariangela Melato"],
            genres: ["Commedia", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["notte d estate", "profilo greco"],
            title: "Notte d'estate con profilo greco, occhi a mandorla e odore di basilico",
            director: "Lina Wertmuller",
            year: 1986,
            actors: ["Mariangela Melato", "Michele Placido"],
            genres: ["Commedia"]
        ),
        ManualMovieCorrection(
            contains: ["ro go pa g"],
            title: "Ro.Go.Pa.G.",
            director: "Roberto Rossellini, Jean-Luc Godard, Pier Paolo Pasolini, Ugo Gregoretti",
            year: 1963,
            actors: ["Orson Welles", "Ugo Tognazzi"],
            genres: ["Commedia", "Drammatico"]
        ),
        ManualMovieCorrection(
            contains: ["seconds 1966"],
            title: "Operazione diabolica",
            director: "John Frankenheimer",
            year: 1966,
            actors: ["Rock Hudson", "Salome Jens"],
            genres: ["Fantascienza", "Thriller"]
        ),
        ManualMovieCorrection(
            contains: ["matrix 1999"],
            title: "Matrix",
            director: "Lana Wachowski, Lilly Wachowski",
            year: 1999,
            actors: ["Keanu Reeves", "Laurence Fishburne", "Carrie-Anne Moss"],
            genres: ["Fantascienza", "Azione"]
        ),
        ManualMovieCorrection(
            contains: ["matrix reloaded"],
            title: "Matrix Reloaded",
            director: "Lana Wachowski, Lilly Wachowski",
            year: 2003,
            actors: ["Keanu Reeves", "Laurence Fishburne", "Carrie-Anne Moss"],
            genres: ["Fantascienza", "Azione"]
        ),
        ManualMovieCorrection(
            contains: ["matrix revolution"],
            title: "Matrix Revolutions",
            director: "Lana Wachowski, Lilly Wachowski",
            year: 2003,
            actors: ["Keanu Reeves", "Laurence Fishburne", "Carrie-Anne Moss"],
            genres: ["Fantascienza", "Azione"]
        ),
        ManualMovieCorrection(
            contains: ["matrix resurrections"],
            title: "Matrix Resurrections",
            director: "Lana Wachowski",
            year: 2021,
            actors: ["Keanu Reeves", "Carrie-Anne Moss", "Yahya Abdul-Mateen II"],
            genres: ["Fantascienza", "Azione"]
        ),
        ManualMovieCorrection(
            contains: ["harry potter 1"],
            title: "Harry Potter e la pietra filosofale",
            director: "Chris Columbus",
            year: 2001,
            actors: ["Daniel Radcliffe", "Rupert Grint", "Emma Watson"],
            genres: ["Fantasy", "Avventura"]
        ),
        ManualMovieCorrection(
            contains: ["harry potter 2"],
            title: "Harry Potter e la camera dei segreti",
            director: "Chris Columbus",
            year: 2002,
            actors: ["Daniel Radcliffe", "Rupert Grint", "Emma Watson"],
            genres: ["Fantasy", "Avventura"]
        ),
        ManualMovieCorrection(
            contains: ["harry potter 3"],
            title: "Harry Potter e il prigioniero di Azkaban",
            director: "Alfonso Cuaron",
            year: 2004,
            actors: ["Daniel Radcliffe", "Rupert Grint", "Emma Watson"],
            genres: ["Fantasy", "Avventura"]
        ),
        ManualMovieCorrection(
            contains: ["harry potter 4"],
            title: "Harry Potter e il calice di fuoco",
            director: "Mike Newell",
            year: 2005,
            actors: ["Daniel Radcliffe", "Rupert Grint", "Emma Watson"],
            genres: ["Fantasy", "Avventura"]
        ),
        ManualMovieCorrection(
            contains: ["harry potter 5"],
            title: "Harry Potter e l'Ordine della Fenice",
            director: "David Yates",
            year: 2007,
            actors: ["Daniel Radcliffe", "Rupert Grint", "Emma Watson"],
            genres: ["Fantasy", "Avventura"]
        ),
        ManualMovieCorrection(
            contains: ["harry potter 6"],
            title: "Harry Potter e il principe mezzosangue",
            director: "David Yates",
            year: 2009,
            actors: ["Daniel Radcliffe", "Rupert Grint", "Emma Watson"],
            genres: ["Fantasy", "Avventura"]
        ),
        ManualMovieCorrection(
            contains: ["harry potter 7"],
            title: "Harry Potter e i Doni della Morte - Parte 1",
            director: "David Yates",
            year: 2010,
            actors: ["Daniel Radcliffe", "Rupert Grint", "Emma Watson"],
            genres: ["Fantasy", "Avventura"]
        ),
        ManualMovieCorrection(
            contains: ["harry potter 8"],
            title: "Harry Potter e i Doni della Morte - Parte 2",
            director: "David Yates",
            year: 2011,
            actors: ["Daniel Radcliffe", "Rupert Grint", "Emma Watson"],
            genres: ["Fantasy", "Avventura"]
        )
    ]
}
