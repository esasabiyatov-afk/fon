import UIKit

/// Вкладка «Поиск» как в приложении YouTube: поле сверху, результаты (страница YouTube) прямо под ним,
/// нижние вкладки и мини-плеер остаются на месте. «Недавние» и подсказки — только пока печатаете.
final class SearchViewController: UIViewController, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {
    /// Запрос отправлен — приложение грузит результаты в окно результатов.
    var onSearch: ((String) -> Void)?

    static let barHeight: CGFloat = 56

    private let searchBar = UISearchBar()
    private let tableView = UITableView(frame: .zero, style: .plain)
    private weak var resultsView: UIView?
    private(set) var hasResults = false
    private var lastQuery = ""
    private var suggestions: [String] = []
    private var suggestTask: URLSessionDataTask?
    private static let historyKey = "searchHistory"

    private var history: [String] {
        get { UserDefaults.standard.stringArray(forKey: Self.historyKey) ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(30)), forKey: Self.historyKey) }
    }

    private var showingHistory: Bool { (searchBar.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    private var rows: [String] { showingHistory ? history : suggestions }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        overrideUserInterfaceStyle = .dark

        updatePlaceholder()
        searchBar.searchBarStyle = .minimal
        searchBar.delegate = self
        searchBar.returnKeyType = .search
        searchBar.tintColor = PlayerView.accent
        view.addSubview(searchBar)

        tableView.backgroundColor = .black
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.rowHeight = 50
        tableView.separatorStyle = .none
        view.addSubview(tableView)
        updateEmptyHint()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        let below = CGRect(x: 0, y: Self.barHeight, width: w, height: max(0, view.bounds.height - Self.barHeight))
        searchBar.frame = CGRect(x: 4, y: 0, width: w - 8, height: Self.barHeight)
        tableView.frame = below
        resultsView?.frame = below
    }

    func updatePlaceholder() {
        searchBar.placeholder = Settings.musicMode ? "Песни, исполнители, альбомы" : "Поиск на YouTube"
    }

    /// Окно, где показываются результаты (страница YouTube) — под полем поиска.
    func setResultsView(_ results: UIView) {
        guard results !== resultsView else { return }
        results.removeFromSuperview()
        results.autoresizingMask = []
        view.insertSubview(results, belowSubview: tableView)
        resultsView = results
        view.setNeedsLayout()
        tableView.isHidden = hasResults
    }

    /// Начать ввод: показать «Недавние» или подсказки, поднять клавиатуру.
    func beginSearch(prefill: String?) {
        loadViewIfNeeded()
        if let prefill, !prefill.isEmpty {
            searchBar.text = prefill
            textChanged(prefill)
        }
        showList(true)
        searchBar.becomeFirstResponder()
    }

    private func showList(_ on: Bool) {
        if !on && !hasResults { return } // без результатов под полем — всегда «Недавние»
        reloadRows()
        UIView.transition(with: tableView, duration: 0.2, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.tableView.isHidden = !on
        }
    }

    /// Перерисовать список; подсказка «Ищите…» — только когда строк нет (иначе она просвечивала под подсказками).
    private func reloadRows() {
        tableView.reloadData()
        updateEmptyHint()
    }

    private func updateEmptyHint() {
        guard rows.isEmpty else { tableView.backgroundView = nil; return }
        let label = UILabel()
        label.text = Settings.musicMode ? "Ищите песни, исполнителей и альбомы" : "Ищите видео, музыку и каналы"
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        tableView.backgroundView = label
    }

    // MARK: - Поиск

    private func submit(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        history = [q] + history.filter { $0.caseInsensitiveCompare(q) != .orderedSame }
        lastQuery = q
        searchBar.text = q
        hasResults = true
        searchBar.resignFirstResponder()
        showList(false)
        onSearch?(q)
    }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        submit(searchBar.text ?? "")
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(true, animated: true)
        showList(true)
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        searchBar.setShowsCancelButton(false, animated: true)
    }

    /// «Отмена» — убрать клавиатуру и вернуться к результатам (если они есть).
    func searchBarCancelButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
        if hasResults {
            searchBar.text = lastQuery
            showList(false)
        }
    }

    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        textChanged(searchText)
    }

    private func textChanged(_ searchText: String) {
        suggestTask?.cancel()
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { suggestions = []; reloadRows(); return }
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
                self.reloadRows()
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
        // «↖» — подставить строку в поле и уточнить запрос, не запуская поиск.
        let fill = UIButton(type: .system)
        fill.setImage(UIImage(systemName: "arrow.up.left"), for: .normal)
        fill.tintColor = UIColor(white: 0.6, alpha: 1)
        fill.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        fill.tag = indexPath.row
        fill.addTarget(self, action: #selector(fillTapped(_:)), for: .touchUpInside)
        cell.accessoryView = fill
        return cell
    }

    @objc private func fillTapped(_ sender: UIButton) {
        guard rows.indices.contains(sender.tag) else { return }
        let text = rows[sender.tag] + " "
        searchBar.text = text
        textChanged(text)
    }

    // Заголовок «Недавние» с кнопкой «Очистить».
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard showingHistory, !history.isEmpty else { return nil }
        let header = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 44))
        let label = UILabel()
        label.text = "Недавние"
        label.font = .systemFont(ofSize: 20, weight: .bold)
        label.textColor = .white
        label.frame = CGRect(x: 20, y: 8, width: 200, height: 30)
        header.addSubview(label)
        let clear = UIButton(type: .system)
        clear.setTitle("Очистить", for: .normal)
        clear.tintColor = PlayerView.accent
        clear.frame = CGRect(x: tableView.bounds.width - 110, y: 8, width: 96, height: 30)
        clear.autoresizingMask = [.flexibleLeftMargin]
        clear.contentHorizontalAlignment = .right
        clear.addTarget(self, action: #selector(clearHistory), for: .touchUpInside)
        header.addSubview(clear)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        showingHistory && !history.isEmpty ? 44 : 0
    }

    @objc private func clearHistory() {
        history = []
        reloadRows()
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
        updateEmptyHint()
    }
}
