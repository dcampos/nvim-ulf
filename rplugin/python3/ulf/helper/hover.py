from ..ulf import RequestHelper
from ..core.protocol import Request, RequestMethod
from ..core.logging import debug
from ..core.views import text_document_position_params
from .goto import GotoDefinitionHelper


class HoverHelper(RequestHelper, method=RequestMethod.HOVER):

    def __init__(self, ulf, vim):
        super().__init__(ulf, vim)

    def run(self):
        view = self.current_view()
        point = self.cursor_point()
        session = self.ulf.session_for_view(view, 'hoverProvider')
        if session is not None:
            session.client.execute_request(
                Request.hover(text_document_position_params(view, point)),
                self.handle_response,
                lambda res: debug(res),
                10)
        else:
            debug('Session is none for buffer={}'.format(view.buffer_id))

    def handle_response(self, response):
        if response is not None:
            contents = response.get('contents')
            if not isinstance(contents, list):
                contents = [contents]
            result = []
            for content in contents:
                if isinstance(content, str):
                    result.append(content)
                elif isinstance(content, dict):
                    result.append(content.get('value'))
            self.vim.command('echon "{}"'.format('\n\n'.join(result).replace('"', '\\"')))