import 'dart:async';
import 'package:args/command_runner.dart';
import 'package:file/file.dart';
import 'package:flutterpi_tool/src/application_package_factory.dart';
import 'package:flutterpi_tool/src/cache.dart';
import 'package:flutterpi_tool/src/device/flutterpi_tool_device_manager.dart';
import 'package:flutterpi_tool/src/executable.dart';
import 'package:flutterpi_tool/src/fltool/common.dart';
import 'package:flutterpi_tool/src/fltool/context_runner.dart' as fltool;
import 'package:flutterpi_tool/src/fltool/globals.dart' as globals;
import 'package:flutterpi_tool/src/flutterpi_config.dart';
import 'package:flutterpi_tool/src/more_os_utils.dart';
import 'package:flutterpi_tool/src/device/ssh_utils.dart';
import 'package:github/github.dart' as gh;

mixin FlutterpiCommandMixin on FlutterCommand {
  FlutterpiCache createCustomCache({
    required FileSystem fs,
    required ShutdownHooks shutdownHooks,
    required Logger logger,
    required Platform platform,
    required MoreOperatingSystemUtils os,
    required FlutterProjectFactory projectFactory,
  }) {
    final repo = stringArg('github-artifacts-repo');
    final runId = stringArg('github-artifacts-runid');
    final githubEngineHash = stringArg('github-artifacts-engine-version');
    final token = stringArg('github-artifacts-auth-token');

    if (runId != null) {
      return GithubWorkflowRunFlutterpiCache(
        hooks: shutdownHooks,
        logger: logger,
        fileSystem: fs,
        platform: platform,
        osUtils: os,
        projectFactory: projectFactory,
        repo: repo != null ? gh.RepositorySlug.full(repo) : null,
        runId: runId,
        auth: token != null ? gh.Authentication.bearerToken(token) : null,
        availableEngineVersion: githubEngineHash,
      );
    } else {
      return GithubRepoReleasesFlutterpiCache(
        hooks: shutdownHooks,
        logger: logger,
        fileSystem: fs,
        platform: platform,
        osUtils: os,
        projectFactory: projectFactory,
        repo: repo != null ? gh.RepositorySlug.full(repo) : null,
        auth: token != null ? gh.Authentication.bearerToken(token) : null,
      );
    }
  }

  Logger createLogger() {
    final factory = LoggerFactory(
      outputPreferences: globals.outputPreferences,
      terminal: globals.terminal,
      stdio: globals.stdio,
    );

    return factory.createLogger(
      daemon: false,
      machine: false,
      verbose: boolArg('verbose', global: true),
      prefixedErrors: false,
      windows: globals.platform.isWindows,
    );
  }

  final _contextOverrides = <Type, dynamic Function()>{};

  void addContextOverride<T>(dynamic Function() fn) {
    _contextOverrides[T] = fn;
  }

  void usesCustomCache({bool verboseHelp = false}) {
    argParser.addOption(
      'github-artifacts-repo',
      help: 'The GitHub repository that provides the engine artifacts. If no '
          'run-id is specified, the release of this repository with tag '
          '"engine/<commit-hash>" will be used to look for the engine artifacts.',
      valueHelp: 'owner/repo',
      hide: !verboseHelp,
    );

    argParser.addOption(
      'github-artifacts-runid',
      help: 'If this is specified, use the artifacts produced by this GitHub '
          'Actions workflow run ID to look for the engine artifacts.',
      valueHelp: 'runID',
      hide: !verboseHelp,
    );

    argParser.addOption(
      'github-artifacts-engine-version',
      help: 'If a run-id is specified to download engine artifacts from a '
          'GitHub Actions run, this specifies the version of the engine '
          'artifacts that were built in the run. Specifying this will make '
          'sure the flutter SDK tries to use the right engine version. '
          'If this is not specified, the engine version will not be checked.',
      valueHelp: 'commit-hash',
      hide: !verboseHelp,
    );

    argParser.addOption(
      'github-artifacts-auth-token',
      help: 'The GitHub personal access token to use for downloading engine '
          'artifacts from a private repository. This is required if the '
          'repository is private.',
      valueHelp: 'token',
      hide: !verboseHelp,
    );

    addContextOverride<Cache>(
      () => createCustomCache(
        fs: globals.fs,
        shutdownHooks: globals.shutdownHooks,
        logger: globals.logger,
        platform: globals.platform,
        os: globals.os as MoreOperatingSystemUtils,
        projectFactory: globals.projectFactory,
      ),
    );
  }

  @override
  bool get usingCISystem => false;

  @override
  String? get debugLogsDirectoryPath => null;

  Future<T> runWithContext<T>(FutureOr<T> Function() fn) async {
    return fltool.runInContext(
      fn,
      overrides: {
        TemplateRenderer: () => const MustacheTemplateRenderer(),
        FlutterpiCache: () => GithubRepoReleasesFlutterpiCache(
              hooks: globals.shutdownHooks,
              logger: globals.logger,
              fileSystem: globals.fs,
              platform: globals.platform,
              osUtils: globals.os as MoreOperatingSystemUtils,
              projectFactory: globals.projectFactory,
            ),
        Cache: () => globals.flutterpiCache,
        OperatingSystemUtils: () => MoreOperatingSystemUtils(
              fileSystem: globals.fs,
              logger: globals.logger,
              platform: globals.platform,
              processManager: globals.processManager,
            ),
        Logger: createLogger,
        Artifacts: () => CachedArtifacts(
              fileSystem: globals.fs,
              platform: globals.platform,
              cache: globals.cache,
              operatingSystemUtils: globals.os,
            ),
        Usage: () => DisabledUsage(),
        FlutterPiToolConfig: () => FlutterPiToolConfig(
              fs: globals.fs,
              logger: globals.logger,
              platform: globals.platform,
            ),
        BuildTargets: () => const BuildTargetsImpl(),
        DeviceManager: () => FlutterpiToolDeviceManager(
              logger: globals.logger,
              platform: globals.platform,
              cache: globals.cache as FlutterpiCache,
              operatingSystemUtils: globals.os as MoreOperatingSystemUtils,
              sshUtils: SshUtils(
                processUtils: globals.processUtils,
                defaultRemote: '',
              ),
              flutterpiToolConfig: FlutterPiToolConfig(
                fs: globals.fs,
                logger: globals.logger,
                platform: globals.platform,
              ),
            ),
        ApplicationPackageFactory: () => FlutterpiApplicationPackageFactory(),
        ..._contextOverrides,
      },
    );
  }

  @override
  Future<FlutterCommandResult> runCommand();

  @override
  Future<void> run() async {
    Cache.flutterRoot = await getFlutterRoot();

    return await runWithContext(() async {
      try {
        final result = await verifyThenRunCommand(null);

        await exitWithHooks(result.exitStatus == ExitStatus.success ? 0 : 1,
            shutdownHooks: globals.shutdownHooks, logger: globals.logger);
      } on ToolExit catch (e) {
        if (e.message != null) {
          globals.printError(e.message!);
        }

        await exitWithHooks(e.exitCode ?? 1, shutdownHooks: globals.shutdownHooks, logger: globals.logger);
      } on UsageException catch (e) {
        globals.printError(e.message);
        globals.printStatus(e.usage);

        await exitWithHooks(1, shutdownHooks: globals.shutdownHooks, logger: globals.logger);
      }
    });
  }
}