from .ulf import ULFHandler
from .core.protocol import Request, Point
from .core.logging import debug
from .core.url import uri_to_filename
from .core.typing import Dict


class WorkspaceSymbolHandler(ULFHandler):

    def run(self, query: str) -> None:
        bufnr = self.vim.current.buffer.number
        session = self.ulf._session_for_buffer(bufnr)
        if session and session.has_capability('workspaceSymbolProvider'):
            session.client.send_request(
                Request.workspaceSymbol({'query': query}),
                self.handle_response,
                lambda res: debug(res))
        else:
            debug('Session is none for buffer={}'.format(bufnr))

    def handle_response(self, response) -> None:
        if not response:
            self.ulf.editor.error_message('No symbol found!')
            return

        self.vim.async_call(self._display_locations, response)

    def _display_locations(self, response):
        def parse_info(location) -> Dict:
            file_name = uri_to_filename(location['location']['uri'])
            point = Point.from_lsp(location['location']['range']['start'])
            row, col = self.ulf.editor.adjust_from_lsp(file_name, point.row, point.col)
            return {'filename': file_name,
                    'lnum': row, 'col': col, 'text': location['name']}

        locations = list(map(parse_info, response))

        self.vim.call('setqflist', locations)
        self.vim.command('copen')
