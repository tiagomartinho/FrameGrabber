import UIKit
import Photos

class AlbumViewController: UICollectionViewController {

    /// nil if deleted.
    var album: FetchedAlbum? {
        get { return dataSource?.album }
        set { configureDataSource(with: newValue) }
    }

    var settings: UserDefaults = .standard

    private var dataSource: AlbumCollectionViewDataSource?

    @IBOutlet private var filterControl: SwipingSegmentedControl!
    @IBOutlet private var emptyView: UIView!

    private lazy var durationFormatter = VideoDurationFormatter()

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        configureViews()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.navigationBar.shadowImage = nil
        navigationController?.navigationBar.layer.shadowOpacity = 0
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        updateThumbnailSize()
    }

    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        if let controller = segue.destination as? EditorViewController {
            prepareForPlayerSegue(with: controller)
        }
    }

    private func prepareForPlayerSegue(with destination: EditorViewController) {
        guard let selectedIndexPath = collectionView?.indexPathsForSelectedItems?.first else { fatalError("Segue without selection or asset") }

        // (todo: Handle this in coordinator/delegate/navigation controller.)
        let transitionController = ZoomTransitionController()
        navigationController?.delegate = transitionController
        destination.transitionController = transitionController

        if let selectedAsset = dataSource?.video(at: selectedIndexPath) {
            destination.videoController = VideoController(asset: selectedAsset)
        }
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard let video = dataSource?.video(at: indexPath) else { return nil }

        let previewImage = (collectionView.cellForItem(at: indexPath) as? VideoCell)?.imageView.image

        return .menu(for: video, previewProvider: { [weak self] in
            self?.imagePreviewController(with: previewImage, scale: 1.2)
        }, toggleFavoriteAction: { [weak self] _ in
            self?.dataSource?.toggleFavorite(for: video)
        }, deleteAction: { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                self?.dataSource?.delete(video)
            }
        })
    }

    override func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating) {
        guard let video = configuration.identifier as? PHAsset,
            let indexPath = dataSource?.indexPath(of: video) else { return }

        animator.addAnimations {
            self.collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
            self.performSegue(withIdentifier: EditorViewController.name, sender: nil)
        }
    }
}

// MARK: - UICollectionViewDelegate

extension AlbumViewController {

    override func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? VideoCell else { return }
        cell.imageRequest = nil
    }
}

// MARK: - Private

private extension AlbumViewController {

    func configureViews() {
        clearsSelectionOnViewWillAppear = false
        collectionView?.alwaysBounceVertical = true
        collectionView?.collectionViewLayout = CollectionViewGridLayout()
        collectionView?.collectionViewLayout.prepare()

        filterControl.installGestures(in: collectionView)
        collectionView.panGestureRecognizer.require(toFail: filterControl.swipeLeftGestureRecognizer)
        collectionView.panGestureRecognizer.require(toFail: filterControl.swipeRightGestureRecognizer)

        if let popGesture = navigationController?.interactivePopGestureRecognizer {
            filterControl.swipeLeftGestureRecognizer.require(toFail: popGesture)
            filterControl.swipeRightGestureRecognizer.require(toFail: popGesture)
        }

        updateViews()
    }

    func configureDataSource(with album: FetchedAlbum?) {
        dataSource = AlbumCollectionViewDataSource(album: album, settings: settings) { [unowned self] in
            self.cell(for: $1, at: $0)
        }

        dataSource?.albumDeletedHandler = { [weak self] in
            // Just show empty screen.
            self?.updateViews()
            self?.collectionView?.reloadData()
        }

        dataSource?.albumChangedHandler = { [weak self] in
            self?.updateViews()
        }

        dataSource?.videosChangedHandler = { [weak self] changeDetails in
            self?.updateViews()

            guard let changeDetails = changeDetails else {
                self?.collectionView.reloadSections([0])
                return
            }

            self?.collectionView?.applyPhotoLibraryChanges(for: changeDetails, cellConfigurator: { 
                self?.reconfigure(cellAt: $0)
            })
        }

        collectionView?.isPrefetchingEnabled = true
        collectionView?.dataSource = dataSource
        collectionView?.prefetchDataSource = dataSource

        updateViews()
        updateThumbnailSize()
    }

    func updateViews() {
        let defaultTitle = NSLocalizedString("album.title.default", value: "Recents", comment: "Title for missing/deleted/initial placeholder album")
        title = dataSource?.album?.title ?? defaultTitle
        collectionView?.backgroundView = (dataSource?.isEmpty ?? true) ? emptyView : nil
        filterControl.selectedSegmentIndex = (dataSource?.type ?? .any).rawValue
    }

    func updateThumbnailSize() {
        guard let layout = collectionView?.collectionViewLayout as? CollectionViewGridLayout else { return }
        dataSource?.imageOptions.size = layout.itemSize.scaledToScreen
    }

    @IBAction func videoTypeSelectionDidChange(_ sender: UISegmentedControl) {
        dataSource?.type = VideoType(sender.selectedSegmentIndex) ?? .any
    }

    func cell(for video: PHAsset, at indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView?.dequeueReusableCell(withReuseIdentifier: VideoCell.name, for: indexPath) as? VideoCell else { fatalError("Wrong cell identifier or type.") }
        configure(cell: cell, for: video)
        return cell
    }

    func configure(cell: VideoCell, for video: PHAsset) {
        cell.durationLabel.text = video.isLivePhoto ? nil : durationFormatter.string(from: video.duration)
        cell.favoritedImageView.isHidden = !video.isFavorite
        loadThumbnail(for: cell, video: video)
    }

    func reconfigure(cellAt indexPath: IndexPath) {
        guard let cell = collectionView?.cellForItem(at: indexPath) as? VideoCell else { return }
        if let video = dataSource?.video(at: indexPath) {
            configure(cell: cell, for: video)
        }
    }

    func loadThumbnail(for cell: VideoCell, video: PHAsset) {
        cell.identifier = video.localIdentifier

        cell.imageRequest = dataSource?.thumbnail(for: video) { image, _ in
            let isCellRecycled = cell.identifier != video.localIdentifier

            guard !isCellRecycled, let image = image else { return }

            cell.imageView.image = image
        }
    }
}
