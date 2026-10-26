import UIKit

/// Поиск как в приложении YouTube: история запросов и подсказки по мере ввода.
final class SearchViewController: UIViewController, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {
    var onSearch: ((String) -> Void)?

    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private var suggestions: [String] = []
    private var suggestTask: URLSessionDataTask?
    private static let historyKey = "searchHistory"

    private var history: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(30)), forKey: Self.historyKey) }
    }

    private var showingHistory: Bool { (searchBar.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    private var rows: [String] { showingHistory ? history : suggestions }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(white: 0.06, alpha: 1)
        overrideUserInterfaceStyle = .dark

        searchBar.placeholder = "Поиск на YouTube"
        searchBar.showsCancelButton = true
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.returnKeyType = .search
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(searchBar)

        tableView.backgroundColor = .clear
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            searchBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            searchBar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 4),
            searchBar.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -4),
            tableView.topAnchor.constraint(equalTo: searchBar.bottomAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        searchBar.becomeFirstResponder()
    }

    // MARK: - Поиск

    private func submit(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        history = [q] + history.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        searchBar.resignFirstResponder()
        dismiss(animated: true) { [onSearch] in onSearch?(q) }
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        submit(searchBar.text ?? "")
    }

    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        dismiss(animated: true)
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        suggestTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { suggestions = []; tableView.reloadData(); return }
        loadSuggestions(for: q)
    }

    /// Подсказки YouTube (тот же сервис, что в приложении).
    private func loadSuggestions(for query: String) {
        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
        components.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "ie", value: "utf-8"),
            URLQueryItem(name: "oe", value: "utf-8"),
            URLQueryItem(name: "q", value: query)
        ]
        guard let url = components.url else { return }
        suggestTask = URLSession.shared.dataTask(with: url) { [weak self] data, response, _ in
            guard let data, let list = Self.parseSuggestions(data, encodingName: response?.textEncodingName) else { return }
            DispatchQueue.main.async {
                guard let self, (self.searchBar.text ?? "").trimmingCharacters(in: .whitespaces) == query else { return }
                self.suggestions = list
                self.tableView.reloadData()
            }
        }
        suggestTask?.resume()
    }

    private static func parseSuggestions(_ data: Data, encodingName: String?) -> [String]? {
        var text: String?
        if let name = encodingName {
            let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cf != kCFStringEncodingInvalidId {
                text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf)))
            }
        }
        if text == nil { text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1251) }
        guard let utf8 = text?.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: utf8) as? [Any],
              json.count > 1, let list = json[1] as? [String] else { return nil }
        return list
    }

    // MARK: - Таблица

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rows.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = rows[indexPath.row]
        content.textProperties.color = .white
        content.image = UIImage(systemName: showingHistory ? "clock.arrow.circlepath" : "magnifyingglass")
        content.imageProperties.tintColor = UIColor(white: 0.6, alpha: 1)
        cell.contentConfiguration = content
        cell.backgroundColor = .clear
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        submit(rows[indexPath.row])
    }

    // Смахнуть запрос из истории
    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool { showingHistory }

    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard showingHistory, editingStyle == .delete else { return }
        var h = history
        h.remove(at: indexPath.row)
        history = h
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }
}
