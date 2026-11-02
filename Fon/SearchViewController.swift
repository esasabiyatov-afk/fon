import UIKit

/// «Поиск»: результаты (страница YouTube) на весь раздел, поле — внизу на стекле, как в iOS 26 (просьба владельца
/// по скриншоту Apple Music): над клавиатурой, а без неё — над панелью вкладок; справа ✕ — закрыть ввод.
/// Нижние вкладки и мини-плеер остаются на месте. «Недавние» и подсказки — только пока печатаете.
final class SearchViewController: UIViewController, UISearchBarDelegate, UITableViewDataSource, UITableViewDelegate {
    /// Запрос отправлен — приложение грузит результаты в окно результатов.
    var onSearch: ((String) -> Void)?

    static let barHeight: CGFloat = 56

    private let searchBar = UISearchBar()
    private let fieldGlass = Glass.make(cornerRadius: 25)
    private let closeGlass = Glass.make(cornerRadius: 25, interactive: true)
    private var fieldTrailing: NSLayoutConstraint!
    private var closeTrailing: NSLayoutConstraint!
    private var fieldToClose: NSLayoutConstraint!
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
        searchBar.backgroundImage = UIImage()
        searchBar.searchTextField.backgroundColor = .clear
        searchBar.searchTextField.font = .systemFont(ofSize: 17)
        searchBar.translatesAutoresizingMaskIntoConstraints = false
        fieldGlass.translatesAutoresizingMaskIntoConstraints = false
        fieldGlass.contentView.addSubview(searchBar)

        let close = UIButton(type: .system)
        close.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        close.tintColor = .white
        close.accessibilityLabel = "Закрыть"
        close.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        close.translatesAutoresizingMaskIntoConstraints = false
        closeGlass.translatesAutoresizingMaskIntoConstraints = false
        closeGlass.contentView.addSubview(close)
        closeGlass.isHidden = true

        tableView.backgroundColor = .black
        tableView.dataSource = self
        tableView.delegate = self
        tableView.keyboardDismissMode = .onDrag
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.rowHeight = 50
        tableView.separatorStyle = .none
        view.addSubview(tableView)
        view.addSubview(fieldGlass)
        view.addSubview(closeGlass)

        // Поле — над клавиатурой; без клавиатуры направляющая клавиатуры = низ раздела (он кончается над панелью вкладок).
        let safe = view.safeAreaLayoutGuide
        fieldTrailing = fieldGlass.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16)
        closeTrailing = closeGlass.trailingAnchor.constraint(equalTo: safe.trailingAnchor, constant: -16)
        fieldToClose = fieldGlass.trailingAnchor.constraint(equalTo: closeGlass.leadingAnchor, constant: -10)
        NSLayoutConstraint.activate([
            fieldGlass.leadingAnchor.constraint(equalTo: safe.leadingAnchor, constant: 16),
            fieldTrailing,
            closeTrailing,
            fieldGlass.heightAnchor.constraint(equalToConstant: Self.barHeight - 6),
            fieldGlass.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -10),
            searchBar.leadingAnchor.constraint(equalTo: fieldGlass.contentView.leadingAnchor, constant: 4),
            searchBar.trailingAnchor.constraint(equalTo: fieldGlass.contentView.trailingAnchor, constant: -4),
            searchBar.centerYAnchor.constraint(equalTo: fieldGlass.contentView.centerYAnchor),
            closeGlass.widthAnchor.constraint(equalToConstant: Self.barHeight - 6),
            closeGlass.heightAnchor.constraint(equalToConstant: Self.barHeight - 6),
            closeGlass.centerYAnchor.constraint(equalTo: fieldGlass.centerYAnchor),
            close.topAnchor.constraint(equalTo: closeGlass.contentView.topAnchor),
            close.bottomAnchor.constraint(equalTo: closeGlass.contentView.bottomAnchor),
            close.leadingAnchor.constraint(equalTo: closeGlass.contentView.leadingAnchor),
            close.trailingAnchor.constraint(equalTo: closeGlass.contentView.trailingAnchor)
        ])
        updateEmptyHint()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let w = view.bounds.width
        let fieldTop = fieldGlass.frame.minY
        // Результаты — до поля; «Недавние» и подсказки — на весь раздел, с отступом под поле.
        resultsView?.frame = CGRect(x: 0, y: 0, width: w, height: max(0, fieldTop - 8))
        tableView.frame = view.bounds
        let inset = max(0, view.bounds.height - fieldTop + 8)
        if tableView.contentInset.bottom != inset {
            tableView.contentInset.bottom = inset
            tableView.verticalScrollIndicatorInsets.bottom = inset
        }
    }

    /// ✕ рядом с полем — пока идёт ввод.
    private func setEditingLayout(_ editing: Bool) {
        guard closeGlass.isHidden == editing else { return }
        if editing {
            fieldTrailing.isActive = false
            fieldToClose.isActive = true
        } else {
            fieldToClose.isActive = false
            fieldTrailing.isActive = true
        }
        closeGlass.isHidden = !editing
        closeGlass.alpha = editing ? 0 : 1
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0, options: [.beginFromCurrentState]) {
            self.closeGlass.alpha = editing ? 1 : 0
            self.view.layoutIfNeeded()
        }
    }

    @objc private func closeTapped() {
        searchBarCancelButtonClicked(searchBar)
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
        setEditingLayout(true)
        showList(true)
    }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) {
        setEditingLayout(false)
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
