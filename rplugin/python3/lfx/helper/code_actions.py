from ..lfx import RequestHelper
from ..editor import VimView
from ..core.edit import parse_workspace_edit
# from ..core.protocol import Diagnostic
from ..core.sessions import Session
from ..core.protocol import Request, RequestMethod, Point, Range
from ..core.typing import Any, List, Dict, Callable, Optional, Union, Tuple, Mapping, TypedDict
from ..core.url import filename_to_uri
# from ..core.logging import debug
from ..diagnostics import filter_by_point, view_diagnostics

CodeActionOrCommand = TypedDict('CodeActionOrCommand', {
    'title': str,
    'command': Union[dict, str],
    'edit': dict
}, total=False)
CodeActionsResponse = Optional[List[CodeActionOrCommand]]
CodeActionsByConfigName = Dict[str, List[CodeActionOrCommand]]


class CodeActionsAtLocation(object):

    def __init__(self, on_complete_handler: Callable[[CodeActionsByConfigName], None]) -> None:
        self._commands_by_config = {}  # type: CodeActionsByConfigName
        self._requested_configs = []  # type: List[str]
        self._on_complete_handler = on_complete_handler

    def collect(self, config_name: str) -> Callable[[CodeActionsResponse], None]:
        self._requested_configs.append(config_name)
        return lambda actions: self.store(config_name, actions)

    def store(self, config_name: str, actions: CodeActionsResponse) -> None:
        self._commands_by_config[config_name] = actions or []
        if len(self._requested_configs) == len(self._commands_by_config):
            self._on_complete_handler(self._commands_by_config)

    def deliver(self, recipient_handler: Callable[[CodeActionsByConfigName], None]) -> None:
        recipient_handler(self._commands_by_config)


class CodeActionsManager(object):
    """ Collects and caches code actions"""

    def __init__(self) -> None:
        self._requests = {}  # type: Dict[str, CodeActionsAtLocation]

    def request(self, view: VimView, location: Any,
                actions_handler: Callable[[CodeActionsByConfigName], None]) -> None:
        current_location = self.get_location_key(view, location)
        # debug("requesting actions for {}".format(current_location))
        if current_location in self._requests:
            self._requests[current_location].deliver(actions_handler)
        else:
            self._requests.clear()
            self._requests[current_location] = request_code_actions(view, location, actions_handler)

    def get_location_key(self, view: VimView, location: Any) -> str:
        if type(location) == Point:
            return "{}#{}:{},{}".format(view.file_name(), view.change_count(), location.row, location.col)
        else:  # Region
            return "{}#{}:{},{}:{},{}".format(view.file_name(), view.change_count(),
                                              location.start.row, location.start.col,
                                              location.end.row, location.end.col)


actions_manager = CodeActionsManager()


def request_code_actions(view: VimView, location: Union[Point, Range],
                         actions_handler: Callable[[CodeActionsByConfigName], None]) -> CodeActionsAtLocation:
    if type(location) == Point:
        return request_code_actions_at_point(view, location, actions_handler)
    else:
        return request_code_actions_for_selection(view, location, actions_handler)


def do_request(session: Session, actions_at_location, file_name, relevant_range, point_diagnostics):
    params = {
        "textDocument": {
            "uri": filename_to_uri(file_name)
        },
        "range": relevant_range.to_lsp(),
        "context": {
            "diagnostics": list(diagnostic.to_lsp() for diagnostic in point_diagnostics)
        }
    }
    if session.client:
        session.client.send_request(
            Request.codeAction(params),
            actions_at_location.collect(session.config.name))


def request_code_actions_for_selection(
    view: VimView,
    selection: Range,
    actions_handler: Callable[[CodeActionsByConfigName], None]
) -> CodeActionsAtLocation:
    actions_at_location = CodeActionsAtLocation(actions_handler)
    for session in view.available_sessions('codeActionProvider'):
        file_name = view.file_name()
        if file_name:
            do_request(session, actions_at_location, file_name, selection, [])
    return actions_at_location


def request_code_actions_at_point(
    view: VimView,
    point: Point,
    actions_handler: Callable[[CodeActionsByConfigName], None]
) -> CodeActionsAtLocation:
    diagnostics_by_config = filter_by_point(view_diagnostics(view), point)
    actions_at_location = CodeActionsAtLocation(actions_handler)
    for session in view.available_sessions('codeActionProvider'):
        point_diagnostics = diagnostics_by_config.get(session.config.name, [])
        if point_diagnostics:
            relevant_range = point_diagnostics[0].range
        else:
            relevant_range = Range(point, point)
        file_name = view.file_name()
        if file_name:
            do_request(session, actions_at_location, file_name, relevant_range, point_diagnostics)
    return actions_at_location


def is_command(command_or_code_action: CodeActionOrCommand) -> bool:
    command_field = command_or_code_action.get('command')
    return isinstance(command_field, str)


def execute_server_command(view: VimView, config_name: str, command: Mapping[str, Any]) -> None:
    session = next((session for session in view.available_sessions() if session.config.name == config_name), None)
    client = session.client or None
    if client:
        client.send_request(Request.executeCommand(command),
                            handle_command_response)


def handle_command_response(response: 'None') -> None:
    pass


def run_code_action_or_command(view: VimView, config_name: str,
                               command_or_code_action: CodeActionOrCommand) -> None:
    if is_command(command_or_code_action):
        execute_server_command(view, config_name, command_or_code_action)
    else:
        # CodeAction can have an edit and/or command.
        maybe_edit = command_or_code_action.get('edit')
        if maybe_edit:
            changes = parse_workspace_edit(maybe_edit)
            window = view.window()
            if window:
                view.editor.apply_workspace_edits(changes)
        maybe_command = command_or_code_action.get('command')
        if isinstance(maybe_command, dict):
            execute_server_command(view, config_name, maybe_command)


class CodeActionsHelper(RequestHelper, method=RequestMethod.CODE_ACTION):

    def __init__(self, lfx, vim) -> None:
        super().__init__(lfx, vim)

    def run(self, options={}) -> None:
        self.options = options
        self.view = self.current_view()  # type: VimView
        self.point = self.cursor_point()
        self.commands = []  # type: List[Tuple[str, str, CodeActionOrCommand]]
        self.commands_by_config = {}  # type: CodeActionsByConfigName
        visual = options.get('visual', False)
        if visual:
            actions_manager.request(self.view, self.selection_range(),
                                    lambda res: self.vim.async_call(self.dispatch_response, res, options))
        else:  # No selection
            actions_manager.request(self.view, self.cursor_point(),
                                    lambda res: self.vim.async_call(self.dispatch_response, res, options))

    def dispatch_response(self, res, options) -> None:
        if self.point != self.cursor_point():
            return
        super().dispatch_response(res, options)

    def combine_commands(self) -> 'List[Tuple[str, str, CodeActionOrCommand]]':
        results = []
        for config, commands in self.commands_by_config.items():
            for command in commands:
                results.append((config, command['title'], command))
        return results

    def handle_response(self, responses: CodeActionsByConfigName):
        self.commands_by_config = responses
        self.commands = self.combine_commands()
        self.show_popup_menu()

    def show_popup_menu(self) -> None:
        options = [command[1] for command in self.commands]
        self.view.editor.show_menu(options, self.handle_select, 'Code actions:')

    def handle_select(self, index: int) -> None:
        if len(self.commands) > index > -1:
            selected = self.commands[index]
            run_code_action_or_command(self.view, selected[0], selected[2])
