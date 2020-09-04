FROM python:3-alpine3.11

RUN apk add --no-cache tini bash wget
RUN pip install mysql-connector python-keycloak PyJWT

ENV JWTSECRET=super-secret-string \
    JWTAUDIENCE=api.dev

COPY api-watch-push.sh create_jwt.py clear_api_data.py clear_keycloak_data.py /home/

CMD ["tini", "--", "/home/api-watch-push.sh"]